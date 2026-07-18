module Hcode
  module Tools
    abstract class Tool
      abstract def name : String
      abstract def description : String
      abstract def parameters : JSON::Any
      abstract def execute(input : JSON::Any) : ToolResult

      def to_definition : LLM::ToolDefinition
        LLM::ToolDefinition.new(
          LLM::ToolFunction.new(name, description, parameters)
        )
      end
    end

    struct ToolResult
      property content : String
      property is_error : Bool = false
      property? truncated : Bool = false

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
