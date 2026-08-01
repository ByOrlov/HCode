require "json"
require "./jsonrpc"
require "./transport"
require "./http_transport"
require "./types"
require "./config"

module Hcode
  module Mcp
    PROTOCOL_VERSION = "2025-06-18"

    # High-level MCP client over a single transport. Owns the JSON-RPC layer,
    # performs the `initialize` handshake, and exposes `tools/list` /
    # `tools/call`. One `Client` corresponds to one configured MCP server.
    # Works over both stdio (child process) and HTTP (Streamable HTTP + SSE).
    class Client
      getter name : String
      getter rpc : JsonRpcClient
      @transport : Transport
      @initialized = false
      @negotiated_version : String? = nil

      def initialize(config : McpServerConfig, override_token : String? = nil)
        @name = config.name
        @transport = config.stdio? ? StdioTransport.new(config) : HttpTransport.new(config, override_token)
        @rpc = JsonRpcClient.new(@transport)
      end

      # For tests: inject a pre-built transport + rpc pair.
      def initialize(@name : String, @transport : Transport, @rpc : JsonRpcClient)
      end

      # Perform the `initialize` request and the `notifications/initialized`
      # back-channel. Must be called once before `list_tools` / `call_tool`.
      def connect(client_name : String = "hcode", client_version : String = Hcode::VERSION,
                  timeout : Time::Span = 30.seconds) : Nil
        params = JSON::Any.new({
          "protocolVersion" => JSON::Any.new(PROTOCOL_VERSION),
          "capabilities"    => JSON::Any.new({} of String => JSON::Any),
          "clientInfo"      => JSON::Any.new({
            "name"    => JSON::Any.new(client_name),
            "version" => JSON::Any.new(client_version),
          } of String => JSON::Any),
        } of String => JSON::Any)
        init_result = rpc.call("initialize", params, timeout)
        # Capture the server's negotiated protocol version. We do not fail on
        # mismatch — servers may legitimately negotiate an older version — but
        # the information is available for diagnostics via `negotiated_version`.
        if v = init_result["protocolVersion"]?
          version = v.to_s
          @negotiated_version = version unless version.empty?
        end
        rpc.notify("notifications/initialized")
        @initialized = true
      end

      def list_tools(timeout : Time::Span = 30.seconds) : Array(ToolDefinition)
        result = rpc.call("tools/list", nil, timeout)
        tools = result["tools"]?.try(&.as_a?) || [] of JSON::Any
        tools.map do |t|
          # Validate inputSchema is a JSON object; default to {} when not,
          # mirroring JS `assertMcpInputSchema` (`types.ts:97-104`).
          raw_schema = t["inputSchema"]?
          schema = if raw_schema && raw_schema.as_h?
                     raw_schema
                   else
                     JSON.parse("{}")
                   end
          ToolDefinition.new(
            t["name"]?.try(&.to_s) || "",
            t["description"]?.try(&.to_s) || "",
            schema,
          )
        end
      end

      def call_tool(remote_name : String, arguments : JSON::Any,
                    timeout : Time::Span = 120.seconds) : CallResult
        params = JSON::Any.new({
          "name"      => JSON::Any.new(remote_name),
          "arguments" => arguments,
        } of String => JSON::Any)
        result = rpc.call("tools/call", params, timeout)
        decode_result(result)
      end

      # Snapshot of stderr from a stdio transport (last ~50 lines). Returns an
      # empty string for non-stdio transports. Used by the Manager to enrich
      # failure messages.
      def stderr_tail : String
        t = @transport
        return "" unless t.is_a?(StdioTransport)
        t.stderr_tail
      end

      def close : Nil
        rpc.close
      end

      def initialized? : Bool
        @initialized
      end

      # The protocol version the server reported during `initialize`. Nil before
      # connect or when the server omitted the field.
      def negotiated_version : String?
        @negotiated_version
      end

      # Fold the raw `tools/call` content blocks into a single string. Text
      # blocks are concatenated; image/audio blocks are embedded as base64
      # data URIs so the model can consume them; resource blocks get a
      # descriptive placeholder (text or blob-decoded depending on type).
      #
      # Handles both the modern `{ content, isError }` shape and the legacy
      # `{ toolResult }` shape (collapsed to a single text block). Mirrors JS
      # `toMcpToolResult`.
      private def decode_result(result : JSON::Any) : CallResult
        # Legacy shape: `{ toolResult: ... }` → single text block.
        if legacy = result["toolResult"]?
          text = legacy.as_s? || legacy.to_s
          return CallResult.new(text, false)
        end

        is_error = result["isError"]?.try(&.as_bool?) == true
        blocks = result["content"]?.try(&.as_a?) || [] of JSON::Any
        parts = [] of String
        blocks.each do |block|
          case block["type"]?.try(&.to_s)
          when "text"
            parts << (block["text"]?.try(&.to_s) || "")
          when "image"
            mime = block["mimeType"]?.try(&.to_s) || "image/png"
            data = block["data"]?.try(&.to_s) || ""
            parts << data_uri(mime, data)
          when "audio"
            mime = block["mimeType"]?.try(&.to_s) || "audio/mpeg"
            data = block["data"]?.try(&.to_s) || ""
            parts << data_uri(mime, data)
          when "resource"
            resource = block["resource"]? || block
            uri = resource["uri"]?.try(&.to_s) || "resource"
            mime = resource["mimeType"]?.try(&.to_s) || "text/plain"
            if text = resource["text"]?
              parts << text.to_s
            elsif blob = resource["blob"]?
              parts << data_uri(mime, blob.to_s)
            else
              parts << "[resource: #{uri}]"
            end
          when "resource_link"
            # resource_link is a URL reference (not an inline blob). Emit the
            # URI so the model can fetch it; mirrors JS `output.ts:137-158`.
            uri = block["uri"]?.try(&.to_s) || ""
            mime = block["mimeType"]?.try(&.to_s) || "application/octet-stream"
            if uri.empty?
              parts << "[resource_link: no uri]"
            else
              parts << "[resource_link: #{uri} (#{mime})]"
            end
          else
            parts << block.to_s
          end
        end
        CallResult.new(parts.join('\n'), is_error)
      end

      # Build a `data:<mime>;base64,<data>` URI. The model sees the raw
      # base64 payload inline; providers that support image_url / audio_url
      # content parts will surface it as media in the conversation.
      private def data_uri(mime : String, base64_data : String) : String
        "data:#{mime};base64,#{base64_data}"
      end
    end
  end
end
