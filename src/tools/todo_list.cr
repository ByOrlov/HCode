module Hcode
  module Tools
    # TodoList — structured TODO list management tool.
    #
    # Contract ported from `packages/agent-core/src/tools/builtin/state/todo-list.ts`:
    #
    #   * Status: `pending` | `in_progress` | `done` (no `cancelled`).
    #   * Field: `title` (no `priority`, no `content`).
    #   * Markers: `[pending]` / `[in_progress]` / `[done]`.
    #   * Query mode: omit `todos` to read the current list without mutation.
    #   * Clear mode: pass `todos: []` to clear.
    #   * Write-reminder appended after every mutation.
    class TodoList < Tool
      TODO_LIST_WRITE_REMINDER =
        "Ensure that you continue to use the todo list to track progress. " \
        "Mark tasks done immediately after finishing them, and keep exactly " \
        "one task in_progress when work is underway."

      getter todos : Array(TodoItem) = [] of TodoItem

      def name : String
        "TodoList"
      end

      def description : String
        "Use this tool to maintain a structured TODO list as you work through a multi-step task. " \
        "Use it proactively and often when progress tracking helps the current work. " \
        "Each item has a title and a status (pending|in_progress|done). " \
        "Omit `todos` to read the current list without changing it; pass an empty array to clear."
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "todos": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "title": {
                    "type": "string",
                    "description": "Short, actionable title for the todo."
                  },
                  "status": {
                    "type": "string",
                    "enum": ["pending", "in_progress", "done"],
                    "description": "Current status of the todo."
                  }
                },
                "required": ["title", "status"]
              },
              "description": "The updated todo list. Omit to read the current todo list without making changes. Pass an empty array to clear the list."
            }
          }
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        todos_input = input["todos"]?

        # Query mode — return the current list without mutation.
        if todos_input.nil?
          return ToolResult.success(format_todos)
        end

        @todos.clear
        todos_input.as_a.each do |item|
          @todos << TodoItem.new(
            title: item["title"]?.try(&.to_s) || "",
            status: parse_status(item["status"]?.try(&.to_s) || "pending"),
          )
        end

        if @todos.empty?
          ToolResult.success("Todo list cleared.")
        else
          "#{format_todos}\n\n#{TODO_LIST_WRITE_REMINDER}"
          ToolResult.success("#{format_todos}\n\n#{TODO_LIST_WRITE_REMINDER}")
        end
      end

      def format_todos : String
        return "Todo list is empty." if @todos.empty?

        lines = @todos.map do |t|
          "  #{status_marker(t.status)} #{t.title}"
        end
        "Current todo list:\n#{lines.join('\n')}"
      end

      # Number of items that still need work — anything not marked done.
      # Used by the agent loop to decide whether to inject a step reminder.
      def pending_count : Int32
        @todos.count { |t| !t.status.done? }
      end

      private def status_marker(status : TodoStatus) : String
        case status
        when .pending?    then "[pending]"
        when .in_progress? then "[in_progress]"
        when .done?       then "[done]"
        else                   "[pending]"
        end
      end

      private def parse_status(s : String) : TodoStatus
        case s.downcase
        when "in_progress" then TodoStatus::InProgress
        when "done"        then TodoStatus::Done
        # Backwards compat: accept the old Crystal "completed" value.
        when "completed"   then TodoStatus::Done
        else                    TodoStatus::Pending
        end
      end
    end

    enum TodoStatus
      Pending
      InProgress
      Done
    end

    struct TodoItem
      property title : String
      property status : TodoStatus

      def initialize(@title : String, @status : TodoStatus)
      end
    end
  end
end
