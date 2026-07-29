require "digest/sha256"

module Hcode
  module Session
    # Metadata persisted as `state.json` inside a v2 session directory.
    # Replaces the legacy flat-layout `meta.json` (which only carried an
    # id + created_at). Fully JSON-serialisable.
    struct StateMeta
      include JSON::Serializable

      property id : String
      property title : String = ""
      property cwd : String = ""
      @[JSON::Field(emit_null: false)]
      property archived : Bool? = nil
      property created_at : String = Time.utc.to_rfc3339
      property updated_at : String = Time.utc.to_rfc3339
      property workspace_id : String = ""

      def initialize(@id : String)
      end

      def archived? : Bool
        @archived == true
      end
    end

    # A session discovered by the Index — its on-disk location plus enough
    # metadata to render a picker / filter without opening the wire log.
    struct SessionEntry
      property id : String
      property path : String          # session directory absolute path
      property wire_path : String     # <path>/wire.jsonl
      property title : String = ""
      property cwd : String = ""
      property? archived : Bool = false
      property created_at : Time = Time.utc
      property updated_at : Time = Time.utc
      property preview : String = ""  # first user prompt (truncated)
      property workspace_id : String = ""
      property? legacy : Bool = false

      def initialize(@id : String, @path : String, @wire_path : String)
      end

      # A human-friendly label: the title if set, else the preview, else the id.
      # Control characters and ANSI escapes are stripped so they cannot corrupt
      # the line-oriented TUI rendering of the session selector.
      def label : String
        raw = @title.empty? ? (@preview.empty? ? @id[0...8] : @preview) : @title
        raw.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
           .gsub(/\e[\(\)][A-B0-9]/, "")
           .gsub(/[\x00-\x08\x0B-\x1F\x7F]/, "")
           .strip
      end
    end

    # Local, filesystem-backed session registry. No HTTP server — the TUI
    # and CLI drive this directly. Scans both the v2 workspace-aware layout
    # (`<sessions>/<workspace_id>/<session>/{wire.jsonl,state.json}`) and
    # the legacy flat layout (`<sessions>/<session>/{wire.jsonl,meta.json}`)
    # so sessions created by older hcode.cr builds stay resumable.
    #
    # Ref: PLAN.md "Session Persistence" + "Local session management".
    class Index
      getter home : String

      def initialize(@home : String = (ENV["HOME"]? || "/tmp"))
      end

      # The sessions root: `<home>/.hcode/sessions`.
      def sessions_root : String
        File.join(@home, ".hcode", "sessions")
      end

      # Derive a stable workspace id from a cwd: the first 12 hex chars of
      # the SHA-256 of the resolved absolute path. Stable across runs for
      # the same directory, filesystem-safe, and short enough for a path
      # segment.
      def self.workspace_id(cwd : String) : String
        resolved = File.expand_path(cwd)
        Digest::SHA256.hexdigest(resolved)[0...12]
      end

      def workspace_id(cwd : String) : String
        self.class.workspace_id(cwd)
      end

      def workspace_dir(ws_id : String) : String
        File.join(sessions_root, ws_id)
      end

      def session_dir(ws_id : String, session_id : String) : String
        File.join(workspace_dir(ws_id), session_id)
      end

      # List sessions, optionally scoped to one workspace. By default
      # archived sessions are hidden. Newest first (by updated_at).
      def list(ws_id : String? = nil, include_archived : Bool = false) : Array(SessionEntry)
        entries = [] of SessionEntry

        if ws_id
          scan_workspace(ws_id, entries)
        else
          # All v2 workspace directories.
          if Dir.exists?(sessions_root)
            Dir.children(sessions_root).each do |name|
              path = File.join(sessions_root, name)
              next unless File.directory?(path)
              # A workspace dir is a 12-hex segment containing session dirs.
              next unless name.match(/\A[0-9a-f]{12}\z/)
              scan_workspace(name, entries)
            end
          end
          # Legacy flat sessions (dirs directly under sessions/ that are
          # NOT workspace ids — they contain wire.jsonl themselves).
          scan_legacy(entries)
        end

        result = include_archived ? entries : entries.reject(&.archived?)
        result.sort_by! { |e| -e.updated_at.to_unix }
      end

      # Find a session by id across every workspace + legacy. Returns the
      # first match (session ids are globally unique random hex).
      def get(session_id : String) : SessionEntry?
        list(include_archived: true).find { |e| e.id == session_id }
      end

      # Most recently updated session, optionally within one workspace.
      def find_most_recent(ws_id : String? = nil) : SessionEntry?
        list(ws_id).first?
      end

      # Are there any (non-archived) sessions in the given workspace?
      def empty?(ws_id : String? = nil) : Bool
        list(ws_id).empty?
      end

      # ---- internal scanners ---------------------------------------------

      private def scan_workspace(ws_id : String, entries : Array(SessionEntry)) : Nil
        ws_dir = workspace_dir(ws_id)
        return unless Dir.exists?(ws_dir)
        Dir.children(ws_dir).each do |name|
          path = File.join(ws_dir, name)
          next unless File.directory?(path)
          wire = File.join(path, "wire.jsonl")
          next unless File.exists?(wire)
          entries << build_entry(name, path, wire, ws_id, false)
        end
      end

      private def scan_legacy(entries : Array(SessionEntry)) : Nil
        return unless Dir.exists?(sessions_root)
        Dir.children(sessions_root).each do |name|
          path = File.join(sessions_root, name)
          next unless File.directory?(path)
          # Skip v2 workspace dirs (handled by scan_workspace).
          next if name.match(/\A[0-9a-f]{12}\z/)
          wire = File.join(path, "wire.jsonl")
          next unless File.exists?(wire)
          entries << build_entry(name, path, wire, "", true)
        end
      end

      private def build_entry(id : String, path : String, wire : String,
                              ws_id : String, legacy : Bool) : SessionEntry
        entry = SessionEntry.new(id, path, wire)
        entry.workspace_id = ws_id
        entry.legacy = legacy

        # Prefer v2 state.json, fall back to legacy meta.json.
        meta = read_state(path) || read_legacy_meta(path)
        if meta
          entry.title = meta.title
          entry.cwd = meta.cwd
          entry.archived = meta.archived?
          entry.workspace_id = ws_id.empty? ? meta.workspace_id : ws_id
        end

        # Timestamps from the wire file's mtime (always present).
        if info = File.info?(wire)
          entry.updated_at = info.modification_time
          entry.created_at = info.modification_time
        end

        entry.preview = first_prompt(wire)
        entry
      end

      private def read_state(path : String) : StateMeta?
        state_path = File.join(path, "state.json")
        return nil unless File.exists?(state_path)
        StateMeta.from_json(File.read(state_path))
      rescue ex : JSON::ParseException
        nil
      end

      private def read_legacy_meta(path : String) : StateMeta?
        meta_path = File.join(path, "meta.json")
        return nil unless File.exists?(meta_path)
        meta = JSON.parse(File.read(meta_path))
        state = StateMeta.new(meta["id"]?.try(&.to_s) || File.basename(path))
        state.title = meta["title"]?.try(&.to_s) || ""
        state.cwd = meta["cwd"]?.try(&.to_s) || ""
        state.created_at = meta["created_at"]?.try(&.to_s) || Time.utc.to_rfc3339
        state
      rescue ex : JSON::ParseException
        nil
      end

      private def first_prompt(wire : String) : String
        File.each_line(wire) do |line|
          next if line.strip.empty?
          begin
            parsed = JSON.parse(line)
            return "" unless parsed["type"]? == "turn.prompt"
            data = parsed["data"]?
            prompt = data.try(&.["prompt"]?).try(&.to_s) || ""
            return sanitize_preview(prompt)[0...80]
          rescue JSON::ParseException
            next
          end
        end
        ""
      rescue File::Error
        ""
      end

      # Strip ANSI escape sequences and other control characters so a prompt
      # containing raw terminal escapes (e.g. cursor movement) cannot corrupt
      # the session selector's line-oriented rendering.
      private def sanitize_preview(text : String) : String
        text.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
            .gsub(/\e[\(\)][A-B0-9]/, "")
            .gsub(/[\x00-\x08\x0B-\x1F\x7F]/, "")
            .strip
      end
    end
  end
end
