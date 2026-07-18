module Hcode
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
        CommandInfo.new("/rename", "Rename the current session", "<title>"),
        CommandInfo.new("/title", "Set session title (alias for /rename)", "<title>"),
        CommandInfo.new("/clear", "Clear conversation history"),
        CommandInfo.new("/compact", "Summarize context to free space"),
        CommandInfo.new("/model", "Switch model"),
        CommandInfo.new("/provider", "Switch LLM provider"),
        CommandInfo.new("/status", "Show session status"),
        CommandInfo.new("/undo", "Undo last turn"),
        CommandInfo.new("/yolo", "Set permission mode to yolo"),
        CommandInfo.new("/auto", "Set permission mode to auto"),
        CommandInfo.new("/manual", "Set permission mode to manual"),
        CommandInfo.new("/export-md", "Export session to markdown file", "[<path>]"),
        CommandInfo.new("/add-dir", "Add working directory", "<path>"),
        CommandInfo.new("/theme", "Switch theme", "dark|light"),
        CommandInfo.new("/version", "Show version information"),
        CommandInfo.new("/usage", "Show token usage and context"),
        CommandInfo.new("/queue", "Show or clear the queued messages", "[clear]"),
        CommandInfo.new("/todos", "Show or clear the agent todo list", "[clear]"),
        CommandInfo.new("/editor", "Open $EDITOR to compose a message"),
        CommandInfo.new("/copy", "Copy last assistant message to clipboard"),
        CommandInfo.new("/permission", "Switch permission mode", "manual|auto|yolo"),
        CommandInfo.new("/effort", "Show thinking effort", "low|medium|high"),
        CommandInfo.new("/plan", "Toggle plan mode"),
        CommandInfo.new("/debug", "Dump full session transcript to stdout"),
        CommandInfo.new("/feedback", "Send feedback to the team", "<message>"),
        CommandInfo.new("/reload", "Reload config.toml and session state"),
        CommandInfo.new("/web", "Print session URL for the Web UI"),
        CommandInfo.new("/settings", "Show current configuration"),
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
