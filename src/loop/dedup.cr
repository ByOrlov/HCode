module Kimi
  module Loop
    class DedupTracker
      MAX_STREAK = 12

      @call_history : Hash(String, Array({String, String})) = {} of String => Array({String, String})

      def check_and_track(tool_name : String, canonical_args : String) : DedupAction
        key = tool_name
        current = {tool_name, canonical_args}

        history = @call_history[key]? || [] of {String, String}

        streak = 0
        history.reverse_each do |entry|
          break if entry[1] != canonical_args
          streak += 1
        end

        new_streak = streak + 1
        history << current
        @call_history[key] = history

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
