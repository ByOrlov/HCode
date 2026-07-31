require "json"
require "../tools/tool"
require "./client"
require "./tool_naming"
require "./output"

module Hcode
  module Mcp
    # A proxy tool registered from the on-disk cache, before the MCP server
    # has connected. Identity (name/description/parameters) is static and
    # needs no client. On first `execute`, the server is connected on demand
    # via `Manager#ensure_connected`; subsequent calls reuse the live client.
    class McpLazyProxyTool < Tools::Tool
      @tool_timeout : Time::Span?
      @manager : Manager
      @server_name : String

      def initialize(@proxy_name : String, @server_name : String,
                     @remote_name : String, @description : String,
                     @parameters : JSON::Any, @manager : Manager,
                     @tool_timeout : Time::Span? = nil)
      end

      def name : String
        @proxy_name
      end

      def description : String
        @description
      end

      def parameters : JSON::Any
        @parameters
      end

      def execute(input : JSON::Any) : Tools::ToolResult
        client = @manager.ensure_connected(@server_name)
        result = client.call_tool(@remote_name, input, timeout: @tool_timeout || 120.seconds)
        processed = Output.post_process(result.text, @proxy_name)
        Tools::ToolResult.new(processed, result.is_error?)
      rescue ex : RpcError
        Tools::ToolResult.error("MCP server '#{@server_name}' tool '#{@remote_name}' failed: #{ex.message}")
      rescue ex
        Tools::ToolResult.error("MCP call failed: #{ex.message}")
      end
    end
  end
end
