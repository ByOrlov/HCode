require "./sensitive"

module Hcode
  module Tools
    # Shared ripgrep subprocess plumbing for Glob and Grep.
    #
    # Single place that knows how to spawn `rg`: timeout / cap'd stdout+stderr
    # draining, two-phase kill, and the standard exclusion globs (VCS metadata
    # + sensitive files). Ported (in spirit) from
    # `packages/agent-core/src/tools/support/run-rg.ts`.
    module RunRg
      DEFAULT_TIMEOUT_S    =   20
      SIGTERM_GRACE_S      =    5
      MAX_OUTPUT_BYTES     =   10 * 1024 * 1024 # 10 MiB
      MAX_STDERR_BYTES     =    1 * 1024 * 1024 # 1 MiB

      # VCS metadata directories excluded from search. Mirrors
      # `VCS_DIRECTORIES_TO_EXCLUDE` in `support/run-rg.ts`.
      VCS_DIRECTORIES_TO_EXCLUDE = [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"]

      # Prefilter globs: VCS metadata + sensitive files. Mirrors
      # `SENSITIVE_GLOBS_TO_EXCLUDE` + `VCS_DIRECTORIES_TO_EXCLUDE` in
      # `support/run-rg.ts`. The authoritative check still runs on parsed
      # records via `PathAccess.sensitive?`.
      def self.exclude_globs : Array(String)
        globs = [] of String
        VCS_DIRECTORIES_TO_EXCLUDE.each { |d| globs << "!#{d}"; globs << "!#{d}/**" }
        Sensitive.globs_to_exclude.each { |g| globs << "!#{g}" }
        globs
      end

      record Result,
        exit_code : Int32,
        stdout_text : String,
        stderr_text : String,
        buffer_truncated : Bool,
        timed_out : Bool

      # Run `rg` with `args`. Returns the captured stdout/stderr (capped at
      # MAX_OUTPUT_BYTES / MAX_STDERR_BYTES) and an `exit_code`. On timeout the
      # process is SIGTERM'd, then SIGKILL'd after `SIGTERM_GRACE_S`.
      def self.run(args : Array(String), *, chdir : String? = nil, timeout_s : Int32 = DEFAULT_TIMEOUT_S) : Result
        process = Process.new(
          "rg",
          args,
          shell: false,
          chdir: chdir,
          input: Process::Redirect::Close,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
        )

        # Close stdin immediately so interactive rg prompts (none by default,
        # but defensive) never hang.
        process.input?.try(&.close)

        stdout_buf = IO::Memory.new
        stderr_buf = IO::Memory.new
        stdout_done = Channel(Nil).new
        stderr_done = Channel(Nil).new

        spawn do
          copy_capped(process.output, stdout_buf, MAX_OUTPUT_BYTES)
          stdout_done.send(nil)
        end

        spawn do
          copy_capped(process.error, stderr_buf, MAX_STDERR_BYTES)
          stderr_done.send(nil)
        end

        status_ch = Channel(Process::Status).new
        spawn { status_ch.send(process.wait) }

        timed_out = false
        status =
          select
          when s = status_ch.receive
            s
          when timeout(timeout_s.seconds)
            timed_out = true
            begin
              process.terminate
            rescue
            end
            select
            when s = status_ch.receive
              s
            when timeout(SIGTERM_GRACE_S.seconds)
              process.terminate(graceful: false) rescue nil
              status_ch.receive
            end
          end

        # Drain remaining streams before reading buffers.
        select
        when stdout_done.receive
        when timeout(2.seconds)
          # best-effort drain; move on
        end
        select
        when stderr_done.receive
        when timeout(2.seconds)
          # best-effort drain; move on
        end

        stdout_text = stdout_buf.to_s
        stderr_text = stderr_buf.to_s
        # If we hit the byte cap mid-stream, `copy_capped` stopped reading and
        # the process may still be writing; treat as truncated.
        buffer_truncated = stdout_text.bytesize >= MAX_OUTPUT_BYTES

        Result.new(
          exit_code: status.exit_code || -1,
          stdout_text: stdout_text,
          stderr_text: stderr_text,
          buffer_truncated: buffer_truncated,
          timed_out: timed_out,
        )
      rescue ex : File::NotFoundError
        # rg binary not present — surface as a recognizable error so tools can
        # produce the JS-style "install ripgrep" message.
        raise RgUnavailableError.new(ex.message || "rg not found")
      end

      class RgUnavailableError < Exception
      end

      private def self.copy_capped(src : IO, dst : IO, max_bytes : Int32) : Nil
        buf = uninitialized UInt8[8192]
        written = 0
        loop do
          n = src.read(buf.to_slice).to_i32
          break if n <= 0
          remaining = max_bytes - written
          break if remaining <= 0
          take = {n, remaining}.min
          dst.write(buf.to_slice[0, take])
          written += take
          break if written >= max_bytes
        end
      rescue IO::Error
        # Best-effort drain — process closed or EPIPE.
      end
    end
  end
end
