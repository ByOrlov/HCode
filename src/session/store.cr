require "./index"

module Kimi
  module Session
    class Store
      property session_dir : String
      property wire_path : String
      property state_path : String

      def initialize(@session_dir : String)
        @wire_path = File.join(@session_dir, "wire.jsonl")
        # v2 layout uses state.json (richer metadata); the legacy flat
        # layout used meta.json. Both are supported on read.
        @state_path = File.join(@session_dir, "state.json")
        Dir.mkdir_p(@session_dir) unless Dir.exists?(@session_dir)
      end

      def self.new_session(home : String) : Store
        session_id = Random::Secure.hex(12)
        dir = File.join(home, ".kimi", "sessions", session_id)
        store = new(dir)
        store.write_meta({"id" => session_id, "created_at" => Time.utc.to_rfc3339})
        store
      end

      # Create a workspace-aware session (v2 layout). The session lands in
      # `<sessions>/<workspace_id>/<session_id>/` and is stamped with a
      # state.json so the Index can discover it.
      def self.new_workspace_session(home : String, cwd : String,
                                     title : String = "") : Store
        ws_id = Index.workspace_id(cwd)
        session_id = Random::Secure.hex(12)
        dir = File.join(home, ".kimi", "sessions", ws_id, session_id)
        store = new(dir)
        meta = StateMeta.new(session_id)
        meta.cwd = cwd
        meta.title = title
        meta.workspace_id = ws_id
        now = Time.utc.to_rfc3339
        meta.created_at = now
        meta.updated_at = now
        store.write_state(meta)
        store.ensure_wire
        store
      end

      def append(event_type : String, data : Hash(String, JSON::Any)) : Nil
        record = {
          "type"      => JSON::Any.new(event_type),
          "timestamp" => JSON::Any.new(Time.utc.to_rfc3339),
          "data"      => JSON::Any.new(data),
        }
        File.open(@wire_path, "a") do |f|
          f.puts(record.to_json)
          f.fsync
        end
      end

      # Create an empty wire.jsonl if it does not exist yet, so the Index
      # can discover a freshly-created session before the first event.
      def ensure_wire : Nil
        return if File.exists?(@wire_path)
        File.write(@wire_path, "")
      end

      def append_simple(event_type : String, key : String, value : String) : Nil
        append(event_type, {key => JSON::Any.new(value)})
      end

      def read_events : Array(NamedTuple(type: String, data: JSON::Any))
        return [] of NamedTuple(type: String, data: JSON::Any) unless File.exists?(@wire_path)

        events = [] of NamedTuple(type: String, data: JSON::Any)

        File.each_line(@wire_path) do |line|
          next if line.strip.empty?
          begin
            parsed = JSON.parse(line)
            events << {
              type: parsed["type"].to_s,
              data: parsed["data"],
            }
          rescue JSON::ParseException
          end
        end

        events
      end

      def write_meta(meta : Hash(String, String)) : Nil
        meta_path = File.join(@session_dir, "meta.json")
        File.write(meta_path, meta.to_json)
      end

      # Write the v2 state.json metadata document.
      def write_state(meta : StateMeta) : Nil
        meta.updated_at = Time.utc.to_rfc3339
        File.write(@state_path, meta.to_json)
      end

      def read_meta : JSON::Any?
        meta_path = File.join(@session_dir, "meta.json")
        return nil unless File.exists?(meta_path)
        JSON.parse(File.read(meta_path))
      rescue
        nil
      end

      # Read the v2 state.json, falling back to a StateMeta synthesised
      # from the legacy meta.json when only the flat layout exists.
      def read_state : StateMeta?
        if File.exists?(@state_path)
          return StateMeta.from_json(File.read(@state_path))
        end
        # Legacy fallback: rebuild a StateMeta from meta.json.
        legacy = read_meta
        return nil unless legacy
        state = StateMeta.new(legacy["id"]?.try(&.to_s) || File.basename(@session_dir))
        state.title = legacy["title"]?.try(&.to_s) || ""
        state.cwd = legacy["cwd"]?.try(&.to_s) || ""
        state.created_at = legacy["created_at"]?.try(&.to_s) || Time.utc.to_rfc3339
        state
      rescue JSON::ParseException
        nil
      end

      def meta_id? : String?
        read_meta.try(&.["id"]?).try(&.to_s)
      end

      def replay(memory : Context::Memory) : Nil
        read_events.each do |event|
          case event[:type]
          when "turn.prompt"
            if prompt = event[:data]["prompt"]?
              memory.add_user(prompt.to_s)
            end
          when "turn.steer"
            if prompt = event[:data]["prompt"]?
              memory.add_user(prompt.to_s)
            end
          when "assistant.text"
            if content = event[:data]["content"]?
              memory.add_assistant(content.to_s)
            end
          when "tool.call"
            tool_name = event[:data]["tool_name"]?.try(&.to_s) || ""
            args = event[:data]["arguments"]?.try(&.to_s) || "{}"
            id = event[:data]["tool_call_id"]?.try(&.to_s) || ""
            tool_call = LLM::ToolCall.new(id, LLM::ToolCallFunction.new(tool_name, args))
            memory.add_assistant("", [tool_call])
          when "tool.result"
            id = event[:data]["tool_call_id"]?
            content = event[:data]["content"]?
            if id && content
              memory.add_tool_result(id.to_s, content.to_s)
            end
          when "context.apply_compaction"
            if summary = event[:data]["summary"]?
              memory.apply_compaction(summary.to_s, [] of Context::ContextMessage)
            end
          end
        end
      end

      def self.list_sessions(home : String) : Array(SessionInfo)
        sessions_dir = File.join(home, ".kimi", "sessions")
        return [] of SessionInfo unless Dir.exists?(sessions_dir)

        sessions = [] of SessionInfo

        Dir.children(sessions_dir).each do |dir_name|
          dir_path = File.join(sessions_dir, dir_name)
          next unless File.directory?(dir_path)

          wire = File.join(dir_path, "wire.jsonl")
          next unless File.exists?(wire)

          first_line = File.read_lines(wire).first?
          preview = ""
          if first_line
            begin
              parsed = JSON.parse(first_line)
              if data = parsed["data"]?
                if prompt = data["prompt"]?
                  preview = prompt.to_s[0...80]
                end
              end
            rescue
            end
          end

          sessions << SessionInfo.new(
            id: dir_name,
            path: dir_path,
            preview: preview,
            created_at: File.info(wire).modification_time,
          )
        end

        sessions.sort_by! { |s| -s.created_at.to_unix }
      end
    end

    struct SessionInfo
      property id : String
      property path : String
      property preview : String
      property created_at : Time

      def initialize(@id : String, @path : String, @preview : String, @created_at : Time)
      end
    end
  end
end
