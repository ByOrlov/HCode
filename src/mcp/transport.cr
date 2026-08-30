require "../process_port"

module H2code
  module Mcp
    # A line-delimited, bidirectional byte transport for JSON-RPC. The stdio
    # transport (a child process) is the only MVP implementation; the abstract
    # base exists so the JSON-RPC client does not depend on `Process`.
    abstract class Transport
      # Write one JSON-RPC message terminated by a newline.
      abstract def write_line(json : String) : Nil
      # Read the next message line, or nil at EOF.
      abstract def read_line? : String?
      # Tear down the underlying transport (kill the process, close the socket).
      abstract def close : Nil
      abstract def closed? : Bool
    end

    # stdio transport: spawns the configured MCP server command and exchanges
    # newline-delimited JSON over its stdin/stdout. stderr is drained into a
    # bounded ring so a chatty server cannot deadlock the pipe.
    class StdioTransport < Transport
      @process : Process?
      @stderr_buf = Array(String).new
      @closed = false
      @input : IO::FileDescriptor
      @output : IO::FileDescriptor
      @error : IO::FileDescriptor

      def initialize(config : McpServerConfig)
        env = ENV.to_h
        config.env.each { |k, v| env[k] = v }

        process = if cwd = config.cwd
                    Process.new(
                      config.command,
                      args: config.args,
                      env: env,
                      chdir: cwd,
                      input: Process::Redirect::Pipe,
                      output: Process::Redirect::Pipe,
                      error: Process::Redirect::Pipe,
                      shell: false,
                    )
                  else
                    Process.new(
                      config.command,
                      args: config.args,
                      env: env,
                      input: Process::Redirect::Pipe,
                      output: Process::Redirect::Pipe,
                      error: Process::Redirect::Pipe,
                      shell: false,
                    )
                  end
        @process = process
        @input = process.input
        @output = process.output
        @error = process.error
        # Drain stderr off-thread so a full OS pipe buffer cannot block the
        # server's stdout. Last ~50 lines are retained for diagnostics.
        spawn(name: "mcp-stderr-#{config.name}") { drain_stderr }
      end

      def write_line(json : String) : Nil
        @input.puts(json)
        @input.flush
      end

      def read_line? : String?
        @output.gets
      end

      def close : Nil
        return if @closed
        @closed = true
        if process = @process
          process.input.close rescue nil
          # Give the server a brief grace window, then force-kill so a hung
          # child never pins the agent process open. `Process#wait` cannot be
          # used in a `select` directly, so race it against a timer channel.
          port = ::H2code::ProcessPort.default
          wait_ch = Channel(Process::Status).new
          spawn { wait_ch.send(process.wait) rescue nil }
          select
          when wait_ch.receive
          when timeout(2.seconds)
            process.terminate rescue nil
            spawn { wait_ch.send(process.wait) rescue nil } unless wait_ch.closed?
            select
            when wait_ch.receive
            when timeout(1.second)
              port.force_kill(process) rescue nil
            end
          end
        end
        @output.close rescue nil
        @error.close rescue nil
      end

      def closed? : Bool
        @closed
      end

      # Snapshot of the most recent stderr output (for the `/mcp` panel).
      def stderr_tail : String
        @stderr_buf.join('\n')
      end

      private def drain_stderr : Nil
        loop do
          line = @error.gets
          break if line.nil?
          @stderr_buf << line
          @stderr_buf.shift if @stderr_buf.size > 50
        end
      rescue IO::Error
        # stderr pipe closed — stop draining.
      end
    end
  end
end
