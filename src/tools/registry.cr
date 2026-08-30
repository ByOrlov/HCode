module H2code
  module Tools
    # Thread-safe tool registry. MCP servers connect in the background and
    # register their proxy tools from a fibre while the agent loop reads
    # `definitions` on the main request path, so every accessor takes the
    # lock.
    class Registry
      @tools : Hash(String, Tool) = {} of String => Tool
      @mutex = Mutex.new

      def register(tool : Tool) : Nil
        @mutex.synchronize { @tools[tool.name] = tool }
      end

      def unregister(name : String) : Nil
        @mutex.synchronize { @tools.delete(name) }
      end

      def get(name : String) : Tool?
        @mutex.synchronize { @tools[name]? }
      end

      def definitions : Array(LLM::ToolDefinition)
        @mutex.synchronize { @tools.values.map(&.to_definition) }
      end

      def names : Array(String)
        @mutex.synchronize { @tools.keys }
      end

      def size : Int32
        @mutex.synchronize { @tools.size }
      end

      def profiled_bytes : Int64
        @mutex.synchronize { @tools.keys.sum(&.profiled_bytes) }
      end

      def profiled_count : Int32
        @mutex.synchronize { @tools.size }
      end

      def each(&block : Tool ->)
        @mutex.synchronize { @tools.each_value(&block) }
      end
    end
  end
end
