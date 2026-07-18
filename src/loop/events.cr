module Kimi
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

      def self.tool_result(id : String, content : String, is_error : Bool) : Event
        e = new(EventType::ToolResult)
        e.tool_call_id = id
        e.text = content
        e.is_error = is_error
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
    end
  end
end
