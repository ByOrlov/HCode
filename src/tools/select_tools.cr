module Hcode
  module Tools
    # select_tools — progressive tool disclosure loader.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/agent/toolSelect/tools/select-tools.ts`.
    #
    # Единственный тул со snake_case-именем (исторически сложилось в MCP).
    #
    # См. детальный план портирования в `md-tools/select-tools.md`.
    module ToolSelect
      @@service : ToolSelectService?

      def self.service=(s : ToolSelectService?)
        @@service = s
      end

      def self.service : ToolSelectService?
        @@service
      end
    end

    struct LoadToolsResult
      property to_load : Array(String)
      property already_available : Array(String)
      property unknown : Array(String)

      def initialize(@to_load : Array(String) = [] of String,
                     @already_available : Array(String) = [] of String,
                     @unknown : Array(String) = [] of String)
      end
    end

    abstract class ToolSelectService
      abstract def enabled? : Bool
      abstract def load(names : Array(String)) : LoadToolsResult
    end

    # Простейшая in-memory реализация для тестов и MVP.
    # Содержит набор "loadable" имён; активный set пуст по умолчанию.
    class InMemoryToolSelectService < ToolSelectService
      @enabled : Bool = true
      @loadable : Set(String)
      @active : Set(String)

      def initialize(@enabled : Bool = true,
                     loadable : Array(String) = [] of String,
                     active : Array(String) = [] of String)
        @loadable = Set.new(loadable)
        @active = Set.new(active)
      end

      def enabled? : Bool
        @enabled
      end

      def disable! : Nil
        @enabled = false
      end

      def enable! : Nil
        @enabled = true
      end

      def loadable!(name : String) : Nil
        @loadable << name
      end

      def active!(name : String) : Nil
        @active << name
      end

      def load(names : Array(String)) : LoadToolsResult
        result = LoadToolsResult.new
        names.each do |name|
          if @active.includes?(name)
            result.already_available << name
          elsif @loadable.includes?(name)
            @active << name
            result.to_load << name
          else
            result.unknown << name
          end
        end
        result
      end
    end

    class SelectTools < Tool
      DESCRIPTION = <<-TEXT
        Load one or more tools by name so you can call them. All available tool names are listed in the <tools_added>/<tools_removed> announcements in the system context — fold them in order to get the current list. Pass the exact name(s) you need; their full definitions become available immediately, so you can call them directly in your next tool call.
      TEXT

      def name : String
        Names::SELECT_TOOLS
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "names": {
              "type": "array",
              "items": { "type": "string" },
              "minItems": 1,
              "description": "Exact tool names to load, taken from the latest announced tool list."
            }
          },
          "required": ["names"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = ToolSelect.service
        return ToolResult.error("Tool-select service is not initialized.") if service.nil?

        svc = service
        unless svc.enabled?
          return ToolResult.error("select_tools is not available for the current model.")
        end

        names = parse_names(input["names"]?)
        if names.empty?
          return ToolResult.error("`names` must be a non-empty array of tool names.")
        end

        result = svc.load(names)

        lines = [] of String
        if !result.to_load.empty?
          lines << "Loaded: #{result.to_load.join(", ")}"
        end
        if !result.already_available.empty?
          lines << "Already available: #{result.already_available.join(", ")}"
        end
        result.unknown.each do |name|
          lines << "Unknown tool: #{name}. Pick from the latest announced tools list."
        end

        is_error = result.to_load.empty? && result.already_available.empty?
        body = lines.empty? ? "No tools loaded." : lines.join('\n')

        is_error ? ToolResult.error(body) : ToolResult.success(body)
      end

      private def parse_names(value : JSON::Any?) : Array(String)
        return [] of String if value.nil?
        arr = value.as_a?
        return [] of String if arr.nil?
        names = [] of String
        arr.each do |v|
          if s = v.as_s?
            names << s unless s.empty?
          end
        end
        names
      end
    end
  end
end
