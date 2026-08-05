require "json"
require "./transport"

module Hcode
  module Mcp
    # Raised when the server returns a JSON-RPC `error` object or the request
    # times out / the transport dies mid-call.
    class RpcError < Exception
      getter code : Int32
      getter method_name : String

      def initialize(@code : Int32, @method_name : String, message : String)
        @method_name = method_name
        super(message)
      end
    end

    # Minimal JSON-RPC 2.0 client over a line-delimited `Transport`. Each
    # request is assigned a monotonic id; a dedicated reader fiber correlates
    # responses by id and delivers them to the waiting caller's channel.
    # Notifications (messages without an id) are accepted but ignored.
    class JsonRpcClient
      DEFAULT_TIMEOUT = 30.seconds

      @id : Int32 = 0
      @pending : Hash(Int32, Channel(JSON::Any)) = {} of Int32 => Channel(JSON::Any)
      @mutex = Mutex.new
      @closed = false

      def initialize(@transport : Transport)
        spawn(name: "mcp-jsonrpc-reader") { read_loop }
      end

      # Send a request and block (a fiber) for the result. Raises `RpcError`
      # on an error envelope, timeout, or closed transport.
      def call(method : String, params : JSON::Any? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : JSON::Any
        raise RpcError.new(-1, method, "MCP transport closed") if @closed

        id = next_id
        ch = Channel(JSON::Any).new
        @mutex.synchronize { @pending[id] = ch }

        write(build_request(id, method, params))

        result = select
        when r = ch.receive
          r
        when timeout(timeout)
          @mutex.synchronize { @pending.delete(id) }
          raise RpcError.new(-1, method, "MCP request '#{method}' timed out after #{timeout.total_seconds}s")
        end

        if err = result["error"]?
          code = err["code"]?.try(&.as_i?).try(&.to_i) || -1
          msg = err["message"]?.try(&.to_s) || "MCP error"
          raise RpcError.new(code, method, "#{method}: #{msg}")
        end

        result["result"]? || JSON.parse("null")
      end

      # Send a notification (no id, no response expected).
      def notify(method : String, params : JSON::Any? = nil) : Nil
        return if @closed
        env = {} of String => JSON::Any
        env["jsonrpc"] = JSON::Any.new("2.0")
        env["method"] = JSON::Any.new(method)
        env["params"] = params if params
        write(env.to_json)
      end

      def close : Nil
        @closed = true
        @transport.close rescue nil
        fail_pending("MCP client closed")
      end

      # True when the reader fiber has hit EOF or `close` was called.
      def closed? : Bool
        @closed
      end

      private def next_id : Int32
        @mutex.synchronize { @id += 1 }
      end

      private def build_request(id : Int32, method : String, params : JSON::Any?) : String
        env = {} of String => JSON::Any
        env["jsonrpc"] = JSON::Any.new("2.0")
        env["id"] = JSON::Any.new(id.to_i64)
        env["method"] = JSON::Any.new(method)
        env["params"] = params if params
        env.to_json
      end

      private def write(json : String) : Nil
        @mutex.synchronize do
          raise RpcError.new(-1, "", "MCP transport closed") if @closed
          @transport.write_line(json)
        end
      end

      private def read_loop : Nil
        loop do
          line = @transport.read_line?
          break if line.nil?
          line = line.strip
          next if line.empty?
          msg = parse?(line)
          next unless msg
          dispatch(msg)
        end
      rescue ex : IO::Error
        # Transport died — fail any in-flight callers below.
      rescue ex
        # A malformed line should not kill the reader; ignore and continue.
      ensure
        @closed = true
        fail_pending("MCP connection closed")
      end

      private def dispatch(msg : JSON::Any) : Nil
        id = msg["id"]?
        return unless id && (id_int = id.as_i?)
        ch = @mutex.synchronize { @pending.delete(id_int) }
        ch.try(&.send(msg))
      end

      private def fail_pending(message : String) : Nil
        envelope = {
          "error" => JSON::Any.new({
            "code"    => JSON::Any.new(-32000_i64),
            "message" => JSON::Any.new(message),
          } of String => JSON::Any),
        } of String => JSON::Any
        err = JSON::Any.new(envelope)
        channels = @mutex.synchronize do
          vals = @pending.values
          @pending.clear
          vals
        end
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
