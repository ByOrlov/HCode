require "json"
require "../loop/events"

module H2code
  module Acp
    # Pure mapping from H2Code's `Loop::Event` to ACP `session/update` params.
    #
    # Each method returns `JSON::Any` — the `session/update` notification params.
    module EventTranslator
      # Build a `session/update` notification with the given session ID and update payload.
      def self.session_update(session_id : String, update : JSON::Any) : JSON::Any
        JSON.parse(%({"sessionId":#{session_id.to_json},"update":#{update.to_json}}))
      end

      def self.session_update(session_id : String, update : Hash) : JSON::Any
        session_update(session_id, JSON.parse(update.to_json))
      end

      # Assistant text delta → `agent_message_chunk`
      def self.assistant_delta(session_id : String, delta : String) : JSON::Any
        update = %({"kind":"agent_message_chunk","content":[{"type":"text","text":#{delta.to_json}}]})
        session_update(session_id, JSON.parse(update))
      end

      # Thinking/reasoning delta → `agent_thought_chunk`
      def self.thinking_delta(session_id : String, delta : String) : JSON::Any
        update = %({"kind":"agent_thought_chunk","content":[{"type":"text","text":#{delta.to_json}}]})
        session_update(session_id, JSON.parse(update))
      end

      # User message → `user_message_chunk`
      def self.user_message(session_id : String, text : String) : JSON::Any
        update = %({"kind":"user_message_chunk","content":[{"type":"text","text":#{text.to_json}}]})
        session_update(session_id, JSON.parse(update))
      end

      # Tool call start → `tool_call` (CREATE)
      def self.tool_call_start(session_id : String, turn_id : Int32,
                               tool_call_id : String, tool_name : String,
                               args : String) : JSON::Any
        wire_id = wire_id(turn_id, tool_call_id)
        kind = infer_tool_kind(tool_name)
        content_str = args.empty? ? "[]" : %([{"type":"content","content":{"type":"text","text":#{args.to_json}}}])

        update = %({
          "kind": "tool_call",
          "toolCallId": #{wire_id.to_json},
          "title": #{tool_name.to_json},
          "toolKind": #{kind.to_json},
          "status": "in_progress",
          "content": #{content_str}
        })
        session_update(session_id, JSON.parse(update))
      end

      # Tool call delta → `tool_call_update` (cumulative args, REPLACE semantics)
      def self.tool_call_delta(session_id : String, turn_id : Int32,
                               tool_call_id : String, cumulative_args : String) : JSON::Any
        wire_id = wire_id(turn_id, tool_call_id)

        update = %({
          "kind": "tool_call_update",
          "toolCallId": #{wire_id.to_json},
          "content": [{"type":"content","content":{"type":"text","text":#{cumulative_args.to_json}}}]
        })
        session_update(session_id, JSON.parse(update))
      end

      # Tool result → `tool_call_update` (terminal: completed/failed)
      def self.tool_result(session_id : String, turn_id : Int32,
                           tool_call_id : String, content_text : String,
                           is_error : Bool, raw_output : String? = nil) : JSON::Any
        wire_id = wire_id(turn_id, tool_call_id)
        status = is_error ? "failed" : "completed"

        if raw_output
          update = JSON.parse(%({
            "kind": "tool_call_update",
            "toolCallId": #{wire_id.to_json},
            "status": #{status.to_json},
            "content": [{"type":"content","content":{"type":"text","text":#{content_text.to_json}}}],
            "rawOutput": #{raw_output.to_json}
          }))
        else
          update = JSON.parse(%({
            "kind": "tool_call_update",
            "toolCallId": #{wire_id.to_json},
            "status": #{status.to_json},
            "content": [{"type":"content","content":{"type":"text","text":#{content_text.to_json}}}]
          }))
        end
        session_update(session_id, update)
      end

      # Info message → `agent_message_chunk` (lightweight info)
      def self.info_message(session_id : String, text : String) : JSON::Any
        assistant_delta(session_id, text)
      end

      # --- Helpers ---

      # Build a `${turnId}:${toolCallId}` wire ID.
      def self.wire_id(turn_id : Int32, tool_call_id : String) : String
        "#{turn_id}:#{tool_call_id}"
      end

      # Heuristic tool-name → ACP kind mapping.
      def self.infer_tool_kind(name : String) : String
        case name
        when "Read", "Glob", "Grep"  then "read"
        when "Write", "Edit"         then "edit"
        when "Bash"                  then "execute"
        when "FetchURL", "WebSearch" then "fetch"
        else                              "other"
        end
      end

      # Map a `TurnEnd` outcome to an ACP `stopReason`.
      def self.stop_reason(cancelled : Bool) : String
        cancelled ? "cancelled" : "end_turn"
      end
    end
  end
end
