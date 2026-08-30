require "digest/sha256"

module H2code
  module Loop
    class DedupTracker
      MAX_STREAK  = 12
      MAX_HISTORY = 24

      # Per-tool ring of recent canonical-arg digests. The full canonical
      # args string (which for Edit/Write contains the entire old/new or
      # content payload) is reduced to a SHA256 hex digest before storage,
      # so the tracker never retains file contents. Capped at MAX_HISTORY
      # entries per tool via FIFO shift.
      @call_history : Hash(String, Array(String)) = {} of String => Array(String)

      # Deep byte size of the dedup tracker — per-tool rings of SHA256 hex
      # digests (16 bytes each), capped at MAX_HISTORY per tool.
      def profiled_bytes : Int64
        @call_history.values.flatten.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @call_history.values.sum(&.size)
      end

      def check_and_track(tool_name : String, canonical_args : String) : DedupAction
        key = tool_name
        digest = Digest::SHA256.hexdigest(canonical_args)

        history = @call_history[key]? || [] of String

        streak = 0
        history.reverse_each do |stored|
          break if stored != digest
          streak += 1
        end

        history << digest
        history.shift if history.size > MAX_HISTORY
        @call_history[key] = history

        new_streak = streak + 1
        if new_streak >= MAX_STREAK
          DedupAction::ForceStop
        elsif new_streak >= 8
          DedupAction::FinalWarning
        elsif new_streak >= 5
          DedupAction::DecisionMenu
        elsif new_streak >= 3
          DedupAction::Reminder
        else
          DedupAction::Allow
        end
      end

      def reset_step : Nil
      end

      def same_step_dedup?(tool_name : String, args : String, seen : Array({String, String})) : Bool
        seen.any? { |n, a| n == tool_name && a == args }
      end

      enum DedupAction
        Allow
        Reminder
        DecisionMenu
        FinalWarning
        ForceStop
      end
    end
  end
end
