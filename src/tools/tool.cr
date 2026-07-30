module Hcode
  module Tools
    abstract class Tool
      abstract def name : String
      abstract def description : String
      abstract def parameters : JSON::Any
      abstract def execute(input : JSON::Any) : ToolResult

      # Set by ToolBatch before each execute call so tools that spawn
      # subagents (AgentSwarm, Agent) can emit lifecycle events tied to
      # the parent tool_call_id in the transcript.
      property tool_call_id : String = ""

      def to_definition : LLM::ToolDefinition
        LLM::ToolDefinition.new(
          LLM::ToolFunction.new(name, description, parameters)
        )
      end
    end

    # Structured display metadata carried alongside a tool's textual result.
    # Mirrors the TS `ToolInputDisplay` `file_io` / `diff` kinds: decouples TUI
    # rendering (e.g. the Edit diff view) from re-parsing the raw `tool_args`
    # JSON, which is brittle when argument key names drift between the schema
    # and the renderer (see `App#render_edit_diff`).
    struct ToolDisplay
      property kind : String        # "file_io" | "diff" | ...
      property operation : String?  # "read" | "write" | "edit"
      property path : String?
      property before : String?
      property after : String?

      def initialize(@kind : String, @operation : String? = nil, @path : String? = nil,
                     @before : String? = nil, @after : String? = nil)
      end
    end

    struct ToolResult
      property content : String
      property is_error : Bool = false
      property? truncated : Bool = false
      property display : ToolDisplay? = nil

      def initialize(@content : String, @is_error : Bool = false)
      end

      def self.success(content : String) : ToolResult
        new(content, false)
      end

      def self.error(content : String) : ToolResult
        new(content, true)
      end
    end

    class ToolContext
      property work_dir : String
      property timeout_seconds : Int32 = 120

      def initialize(@work_dir : String)
      end
    end
  end
end
