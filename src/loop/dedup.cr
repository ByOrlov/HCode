require "digest/sha256"

module Hcode
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

      def check_and_track(tool_name : String, canonical_args : String) : DedupAction
        key    = tool_name
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
