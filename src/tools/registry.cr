module Kimi
  module Tools
    class Registry
      @tools : Hash(String, Tool) = {} of String => Tool

      def register(tool : Tool) : Nil
        @tools[tool.name] = tool
      end

      def get(name : String) : Tool?
        @tools[name]?
      end

      def definitions : Array(LLM::ToolDefinition)
        @tools.values.map(&.to_definition)
      end

      def names : Array(String)
        @tools.keys
      end

      def size : Int32
        @tools.size
      end

      def each(&block : Tool ->)
        @tools.each_value(&block)
      end
    end
  end
end
