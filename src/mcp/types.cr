module Hcode
  module Mcp
    # One tool advertised by a remote MCP server, decoded from the `tools/list`
    # response. `input_schema` is the raw JSON Schema the server published and
    # is forwarded verbatim as the proxy tool's `parameters`.
    struct ToolDefinition
      getter name : String
      getter description : String
      getter input_schema : JSON::Any

      def initialize(@name : String, @description : String, @input_schema : JSON::Any)
      end
    end

    # Decoded `tools/call` result. MVP is text-only: every content block is
    # folded into `text`; non-text blocks (image/audio/resource) are surfaced
    # as a short placeholder so the model still sees something useful.
    struct CallResult
      getter text : String
      getter? is_error : Bool

      def initialize(@text : String, @is_error : Bool = false)
      end
    end
  end
end
