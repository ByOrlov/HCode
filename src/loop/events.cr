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
      SubagentStarted
      SubagentProgress
      SubagentCompleted
      SubagentFailed
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
      # Optional reasoning text carried alongside assistant_text so it can be
      # persisted to wire.jsonl alongside the visible text.
      property thinking : String? = nil
      # Compaction event payload (CompactionStarted/Completed/Cancelled).
      property tokens_before : Int32? = nil
      property tokens_after : Int32? = nil
      property summary : String = ""
      property tip : String = ""
      # Subagent lifecycle payload fields.
      # `agent_id` identifies the child agent; `tool_call_id` ties it to the
      # parent AgentSwarm/Agent tool call that spawned it. `phase` is the
      # short status label the TUI renders (e.g. "Running", "Completed").
      property agent_id : String = ""
      property swarm_index : Int32 = 0
      property phase : String = ""
      property item_text : String = ""
      property subagent_ticks : Int32 = 0

      def initialize(@type : EventType)
      end

      def self.user_message(text : String) : Event
        e = new(EventType::UserMessage)
        e.text = text
        e
      end

      def self.assistant_text(text : String, thinking : String? = nil) : Event
        e = new(EventType::AssistantText)
        e.text = text
        e.thinking = thinking
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

      # ----------------------------------------------------------------
      # Subagent lifecycle events — emitted by the swarm/agent runners so
      # the TUI can render live per-agent progress. `tool_call_id` ties the
      # event to the parent AgentSwarm/Agent tool call in the transcript.
      # ----------------------------------------------------------------

      def self.subagent_started(tool_call_id : String, agent_id : String,
                                swarm_index : Int32 = 0,
                                item_text : String = "") : Event
        e = new(EventType::SubagentStarted)
        e.tool_call_id = tool_call_id
        e.agent_id = agent_id
        e.swarm_index = swarm_index
        e.item_text = item_text
        e.phase = "Running"
        e
      end

      def self.subagent_progress(tool_call_id : String, agent_id : String,
                                 ticks : Int32) : Event
        e = new(EventType::SubagentProgress)
        e.tool_call_id = tool_call_id
        e.agent_id = agent_id
        e.subagent_ticks = ticks
        e.phase = "Running"
        e
      end

      def self.subagent_completed(tool_call_id : String, agent_id : String) : Event
        e = new(EventType::SubagentCompleted)
        e.tool_call_id = tool_call_id
        e.agent_id = agent_id
        e.phase = "Completed"
        e
      end

      def self.subagent_failed(tool_call_id : String, agent_id : String,
                               error : String = "") : Event
        e = new(EventType::SubagentFailed)
        e.tool_call_id = tool_call_id
        e.agent_id = agent_id
        e.phase = error.empty? ? "Failed" : error
        e
      end
    end
  end
end
