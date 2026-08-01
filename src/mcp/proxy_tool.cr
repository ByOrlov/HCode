require "json"
require "../tools/tool"
require "./client"
require "./tool_naming"
require "./output"

module Hcode
  module Mcp
    class McpProxyTool < Tools::Tool
      @tool_timeout : Time::Span?

      def initialize(@proxy_name : String, @server_name : String,
                     @remote_name : String, @description : String,
                     @parameters : JSON::Any, @client : Client,
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
        result = @client.call_tool(@remote_name, input, timeout: @tool_timeout || 120.seconds)
        processed = Output.post_process(result.text, @proxy_name)
        Tools::ToolResult.new(processed[:text], result.is_error?, truncated: processed[:truncated])
      rescue ex : RpcError
        Tools::ToolResult.error("MCP server '#{@server_name}' tool '#{@remote_name}' failed: #{ex.message}")
      rescue ex
        Tools::ToolResult.error("MCP call failed: #{ex.message}")
      end
    end
  end
end
