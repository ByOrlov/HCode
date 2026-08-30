require "socket"
require "json"

module H2code
  module Remote
    # Per-process control socket for external input (h2code-remote).
    #
    # A running TUI listens on `<session_dir>/control.sock`; the h2code-remote
    # daemon connects as a client and injects prompts/interrupts as synthetic
    # user input via `App#deliver_external_prompt` (the same path cron uses).
    # One listener per process — remote multiplexes by connecting to each
    # session's socket separately.
    #
    # Protocol: newline-delimited UTF-8 JSON, one object per line.
    #   client → {"op":"prompt","text":"..."}
    #   client → {"op":"interrupt"}
    #   client → {"op":"status"}
    #   server ← {"ok":true} | {"ok":false,"error":"..."}
    #             | {"ok":true,"busy":true|false}   (op: status)
    #
    # Unknown ops answer ok:false; malformed lines are skipped. The socket
    # file is unlinked on close/rebind and on exit (best-effort).
    class ControlSocket
      @server : UNIXServer? = nil
      @path : String? = nil

      def initialize(@on_prompt : String -> Nil, @on_interrupt : -> Nil,
                     @on_status : -> Bool = -> { false })
      end

      # (Re)bind to a session directory. Safe to call repeatedly — the old
      # listener is closed first (TUI switches session dirs on /new, /resume
      # and /fork).
      def rebind(session_dir : String) : Nil
        close
        path = File.join(session_dir, "control.sock")
        begin
          File.delete(path) if File.exists?(path)
          server = UNIXServer.new(path)
        rescue ex
          # Non-fatal: remote sync for this session is simply unavailable.
          STDERR.puts "[control-socket] cannot listen on #{path}: #{ex.message}"
          return
        end
        @server = server
        @path = path
        spawn { accept_loop(server) }
      end

      def close : Nil
        server = @server
        path = @path
        @server = nil
        @path = nil
        begin
          server.close if server
        rescue
        end
        begin
          File.delete(path) if path && File.exists?(path)
        rescue
        end
      end

      private def accept_loop(server : UNIXServer) : Nil
        loop do
          client = begin
            server.accept
          rescue
            # Listener closed (rebind/exit).
            break
          end
          spawn { serve(client.as UNIXSocket) }
        end
      end

      private def serve(client : UNIXSocket) : Nil
        client.each_line do |line|
          next if line.strip.empty?
          handle_line(client, line)
        end
      rescue
        # Client disconnected mid-line.
      ensure
        begin
          client.close
        rescue
        end
      end

      private def handle_line(client : UNIXSocket, line : String) : Nil
        op, text = begin
          msg = JSON.parse(line)
          {msg["op"]?.try(&.to_s), msg["text"]?.try(&.to_s)}
        rescue JSON::ParseException
          reply(client, ok: false, error: "malformed JSON")
          return
        end

        case op
        when "prompt"
          if text.nil? || text.strip.empty?
            reply(client, ok: false, error: "empty prompt")
            return
          end
          @on_prompt.call(text || raise "text checked above")
          reply(client, ok: true)
        when "interrupt"
          @on_interrupt.call
          reply(client, ok: true)
        when "status"
          # Authoritative busy flag for h2code-remote's session listing: the
          # wire log has no end-of-turn record (an interrupted turn writes
          # nothing), so the TUI process itself is the source of truth.
          reply(client, ok: true, busy: @on_status.call)
        else
          reply(client, ok: false, error: "unknown op")
        end
      rescue ex
        reply(client, ok: false, error: ex.message || "error")
      end

      private def reply(client : UNIXSocket, ok : Bool, error : String? = nil, busy : Bool? = nil) : Nil
        payload = {"ok" => ok}
        payload = payload.merge({"error" => error}) if error
        payload = payload.merge({"busy" => JSON::Any.new(busy || raise "busy checked above")}) unless busy.nil?
        begin
          client << payload.to_json << '\n'
          client.flush
        rescue
        end
      end
    end
  end
end
