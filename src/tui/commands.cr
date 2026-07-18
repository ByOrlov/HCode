module Kimi
  module TUI
    struct CommandInfo
      property name : String
      property description : String
      property usage : String

      def initialize(@name : String, @description : String, @usage : String = "")
      end
    end

    class CommandRegistry
      COMMANDS = [
        CommandInfo.new("/help", "Show available commands"),
        CommandInfo.new("/exit", "Exit the application"),
        CommandInfo.new("/quit", "Exit the application"),
        CommandInfo.new("/new", "Start a new session"),
        CommandInfo.new("/sessions", "List and resume a session"),
        CommandInfo.new("/resume", "Resume a session (alias for /sessions)"),
        CommandInfo.new("/fork", "Fork the current session"),
        CommandInfo.new("/archive", "Archive the current session"),
        CommandInfo.new("/restore", "Restore an archived session"),
        CommandInfo.new("/rename", "Rename the current session"),
        CommandInfo.new("/title", "Set session title (alias for /rename)"),
        CommandInfo.new("/clear", "Clear conversation history"),
        CommandInfo.new("/compact", "Summarize context to free space"),
        CommandInfo.new("/model", "Switch model"),
        CommandInfo.new("/provider", "Switch LLM provider"),
        CommandInfo.new("/status", "Show session status"),
        CommandInfo.new("/undo", "Undo last turn"),
        CommandInfo.new("/yolo", "Set permission mode to yolo"),
        CommandInfo.new("/auto", "Set permission mode to auto"),
        CommandInfo.new("/manual", "Set permission mode to manual"),
        CommandInfo.new("/export-md", "Export session to markdown file"),
        CommandInfo.new("/add-dir", "Add working directory"),
        CommandInfo.new("/theme", "Switch theme (dark/light)"),
      ]

      def self.names : Array(String)
        COMMANDS.map(&.name)
      end

      def self.find(name : String) : CommandInfo?
        COMMANDS.find { |c| c.name == name }
      end

      def self.match(prefix : String) : Array(CommandInfo)
        return [] of CommandInfo if prefix.empty?
        COMMANDS.select { |c| c.name.starts_with?(prefix) }
      end

      struct ParseResult
        property command : String
        property args : String

        def initialize(@command : String, @args : String = "")
        end
      end

      def self.parse(input : String) : ParseResult?
        return nil unless input.starts_with?('/')
        parts = input.split(' ', 2)
        cmd = parts[0]
        args = parts[1]? || ""
        ParseResult.new(cmd, args.strip)
      end
    end
  end
end
