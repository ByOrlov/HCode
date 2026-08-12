require "json"

module Hcode
  module Acp
    # JSON-RPC 2.0 error codes (ACP-specific negative range starts at -32000).
    module ErrorCodes
      PARSE_ERROR      = -32700
      INVALID_REQUEST  = -32600
      METHOD_NOT_FOUND = -32601
      INVALID_PARAMS   = -32602
      INTERNAL_ERROR   = -32603
      AUTH_REQUIRED    = -32000
    end

    # A structured JSON-RPC error response payload.
    record RpcError,
      code : Int32,
      message : String,
      data : JSON::Any? = nil do
      def to_json_any : JSON::Any
        h = {} of String => JSON::Any
        h["code"] = JSON::Any.new(code.to_i64)
        h["message"] = JSON::Any.new(message)
        h["data"] = data if data
        JSON::Any.new(h)
      end
    end

    # Raised when a reverse-RPC (agent → client) fails or times out.
    class ReverseRpcError < Exception
      getter code : Int32

      def initialize(@code : Int32, message : String)
        super(message)
      end
    end

    # Bidirectional JSON-RPC 2.0 frame over stdin/stdout.
    #
    # The ACP server is both a JSON-RPC *server* (receives requests from the IDE,
    # sends responses) and a JSON-RPC *client* (sends reverse-RPC requests like
    # `session/request_permission` and waits for responses).
    #
    # - Inbound requests/notifications → dispatched to the `handler` block.
    # - Inbound responses → correlated by id and delivered to the waiting caller.
    # - Outbound messages → serialized through a Mutex (STDOUT is shared).
    class JsonRpc
      DEFAULT_REVERSE_RPC_TIMEOUT = 120.seconds

      @writer_lock = Mutex.new
      @pending_lock = Mutex.new
      @pending = {} of Int32 => Channel(JSON::Any)
      @next_id = Atomic(Int32).new(1)
      @closed = false
      @closed_lock = Mutex.new

      def initialize(@input : IO = STDIN, @output : IO = STDOUT)
      end

      # Main read loop. Reads newline-delimited JSON from input, parses each
      # line as JSON-RPC 2.0, and dispatches:
      #   - Requests (has "id" + "method") → handler
      #   - Notifications (has "method", no "id") → handler
      #   - Responses (has "id", no "method") → deliver to pending channel
      #
      # The handler is called in the reader fiber; long-running handlers should
      # spawn their own fibers so the reader doesn't block.
      def run(&handler : JSON::Any -> Nil) : Nil
        loop do
          line = @input.gets
          break if line.nil? # EOF
          line = line.strip
          next if line.empty?

          msg = parse?(line)
          unless msg
            STDERR.puts "[acp] malformed JSON line, skipping"
            next
          end

          # Response to our reverse-RPC?
          if msg["id"]? && !msg["method"]?
            deliver_response(msg)
            next
          end

          # Request or notification → dispatch to handler
          handler.call(msg)
        end
      rescue ex : IO::Error
        # Input closed — normal shutdown path
      ensure
        close
      end

      # --- Outbound: responses to client requests ---

      def send_response(id : Int32, result : JSON::Any) : Nil
        env = {} of String => JSON::Any
        env["jsonrpc"] = JSON::Any.new("2.0")
        env["id"] = JSON::Any.new(id.to_i64)
        env["result"] = result
        write_json(env)
      end

      def send_response(id : Int32, result : Hash) : Nil
        send_response(id, JSON.parse(result.to_json))
      end

      def send_error(id : Int32, code : Int32, message : String, data : JSON::Any? = nil) : Nil
        err = {} of String => JSON::Any
        err["code"] = JSON::Any.new(code.to_i64)
        err["message"] = JSON::Any.new(message)
        err["data"] = data if data
        env = {} of String => JSON::Any
        env["jsonrpc"] = JSON::Any.new("2.0")
        env["id"] = JSON::Any.new(id.to_i64)
        env["error"] = JSON::Any.new(err)
        write_json(env)
      end

      # For notifications (no id) we can't send an error response, so we just
      # log to stderr.
      def log_notification_error(method : String, message : String) : Nil
        STDERR.puts "[acp] notification '#{method}' error: #{message}"
      end

      # --- Outbound: notifications (no response expected) ---

      def send_notification(method : String, params : JSON::Any? = nil) : Nil
        env = {} of String => JSON::Any
        env["jsonrpc"] = JSON::Any.new("2.0")
        env["method"] = JSON::Any.new(method)
        env["params"] = params if params
        write_json(env)
      end

      def send_notification(method : String, params : Hash) : Nil
        send_notification(method, JSON.parse(params.to_json))
      end

      # --- Outbound: reverse-RPC requests (block until response) ---

      def request(method : String, params : JSON::Any? = nil,
                  timeout : Time::Span = DEFAULT_REVERSE_RPC_TIMEOUT) : JSON::Any
        raise ReverseRpcError.new(-1, "ACP connection closed") if closed?

        id = next_id
        ch = Channel(JSON::Any).new
        @pending_lock.synchronize { @pending[id] = ch }

        write_json(build_request_envelope(id, method, params))

        result = select
        when r = ch.receive
          r
        when timeout(timeout)
          @pending_lock.synchronize { @pending.delete(id) }
          raise ReverseRpcError.new(-1, "Reverse-RPC '#{method}' timed out after #{timeout.total_seconds}s")
        end

        if err = result["error"]?
          code = err["code"]?.try(&.as_i?).try(&.to_i) || -1
          msg = err["message"]?.try(&.to_s) || "ACP error"
          raise ReverseRpcError.new(code, "#{method}: #{msg}")
        end

        result["result"]? || JSON.parse("null")
      end

      # --- Lifecycle ---

      def closed? : Bool
        @closed_lock.synchronize { @closed }
      end

      def close : Nil
        @closed_lock.synchronize { @closed = true }
        fail_pending("ACP connection closed")
      end

      # --- Internals ---

      private def next_id : Int32
        @next_id.add(1)
      end

      private def build_request_envelope(id : Int32, method : String, params : JSON::Any?) : Hash(String, JSON::Any)
        env = {} of String => JSON::Any
        env["jsonrpc"] = JSON::Any.new("2.0")
        env["id"] = JSON::Any.new(id.to_i64)
        env["method"] = JSON::Any.new(method)
        env["params"] = params if params
        env
      end

      private def write_json(hash : Hash(String, JSON::Any)) : Nil
        json = hash.to_json
        @writer_lock.synchronize do
          @output.puts(json)
          @output.flush
        end
      rescue ex : IO::Error
        @closed_lock.synchronize { @closed = true }
      end

      private def deliver_response(msg : JSON::Any) : Nil
        id = msg["id"]?
        return unless id && (id_int = id.as_i?)
        ch = @pending_lock.synchronize { @pending.delete(id_int) }
        ch.try(&.send(msg))
      end

      private def fail_pending(message : String) : Nil
        channels = @pending_lock.synchronize do
          vals = @pending.values
          @pending.clear
          vals
        end
        err = JSON.parse(%({"error":{"code":-32000,"message":#{message.inspect}}}))
        channels.each(&.send(err))
      end

      private def parse?(line : String) : JSON::Any?
        JSON.parse(line)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
