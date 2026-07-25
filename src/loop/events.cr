module Hcode
  module Loop
    enum EventType
      UserMessage
      AssistantText
      TextDelta
      ThinkingDelta
      ToolCallStart
      ToolCallDelta
      ToolResult
      StepBegin
      StepEnd
      Info
      Error
      TurnEnd
      CompactionStarted
      CompactionCompleted
      CompactionCancelled
    end

    class Event
      property type : EventType
      property text : String = ""
      property step : Int32 = 0
      property usage : LLM::Usage?
      property tool_call_id : String = ""
      property tool_name : String = ""
      property tool_args : String = ""
      property is_error : Bool = false
      property tool_display : Tools::ToolDisplay? = nil
      # Optional RAM-usage line attached by the CLI (--ram flag) so the TUI
      # can render it inside the tool block instead of as a separate info
      # message. nil when --ram is off.
      property ram_line : String? = nil
      # Compaction event payload (CompactionStarted/Completed/Cancelled).
      property tokens_before : Int32? = nil
      property tokens_after : Int32? = nil
      property summary : String = ""
      property tip : String = ""

      def initialize(@type : EventType)
      end

      def self.user_message(text : String) : Event
        e = new(EventType::UserMessage)
        e.text = text
        e
      end

      def self.assistant_text(text : String) : Event
        e = new(EventType::AssistantText)
        e.text = text
        e
      end

      def self.text_delta(text : String) : Event
        e = new(EventType::TextDelta)
        e.text = text
        e
      end

      def self.thinking_delta(text : String) : Event
        e = new(EventType::ThinkingDelta)
        e.text = text
        e
      end

      def self.tool_call_start(id : String, name : String, args : String) : Event
        e = new(EventType::ToolCallStart)
        e.tool_call_id = id
        e.tool_name = name
        e.tool_args = args
        e
      end

      def self.tool_call_delta(id : String, name : String, args : String) : Event
        e = new(EventType::ToolCallDelta)
        e.tool_call_id = id
        e.tool_name = name
        e.tool_args = args
        e
      end

      def self.tool_result(id : String, content : String, is_error : Bool,
                           display : Tools::ToolDisplay? = nil) : Event
        e = new(EventType::ToolResult)
        e.tool_call_id = id
        e.text = content
        e.is_error = is_error
        e.tool_display = display
        e
      end

      def self.step_begin(step : Int32) : Event
        e = new(EventType::StepBegin)
        e.step = step
        e
      end

      def self.step_end(step : Int32, usage : LLM::Usage) : Event
        e = new(EventType::StepEnd)
        e.step = step
        e.usage = usage
        e
      end

      def self.info(text : String) : Event
        e = new(EventType::Info)
        e.text = text
        e
      end

      def self.error(text : String) : Event
        e = new(EventType::Error)
        e.text = text
        e.is_error = true
        e
      end

      # Emitted exactly once at the end of a turn (whether it completed
      # normally, was cancelled, or errored out). The TUI uses this to drain
      # queued messages — see App#on_event. `cancelled` is true when the turn
      # ended via UserCancellationError / Agent#cancel.
      def self.turn_end(cancelled : Bool = false) : Event
        e = new(EventType::TurnEnd)
        e.is_error = cancelled
        e
      end

      def self.compaction_started(instruction : String? = nil, tip : String? = nil) : Event
        e = new(EventType::CompactionStarted)
        e.text = instruction || ""
        e.tip = tip || ""
        e
      end

      def self.compaction_completed(tokens_before : Int32? = nil,
                                     tokens_after : Int32? = nil,
                                     summary : String? = nil) : Event
        e = new(EventType::CompactionCompleted)
        e.tokens_before = tokens_before
        e.tokens_after = tokens_after
        e.summary = summary || ""
        e
      end

      def self.compaction_cancelled : Event
        new(EventType::CompactionCancelled)
      end
    end
  end
end
