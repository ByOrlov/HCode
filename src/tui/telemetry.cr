module H2code
  module TUI
    # Lightweight counter-delta telemetry. Tracks named render-quality counters
    # and, when a counter increases between two tool-result samples, produces a
    # "counter increased" line that the renderer attaches to the offending tool
    # call in yellow. Designed to be extensible: `COUNTERS` lists every tracked
    # name with its default state; each can be toggled individually via
    # `/telemetry`.
    class Telemetry
      # The registry of tracked counters: name → enabled by default.
      COUNTERS = {
        "SyncBugsCount" => true,
      }

      # Master switch. When false, sampling is a no-op for every counter.
      property? enabled : Bool = true

      # Per-counter enable flags (mutable copy of COUNTERS values).
      getter counters : Hash(String, Bool)

      # Last-seen value for each counter. Updated on every `sample` call so the
      # delta between the previous tool result and the current one is what gets
      # reported.
      @prev_values : Hash(String, Int32)

      def initialize
        @counters = COUNTERS.transform_values { |v| v }
        @prev_values = COUNTERS.transform_values { 0 }
      end

      # Sample a counter value. Returns the positive delta vs the previous
      # sample, or 0 if telemetry is off, the counter is disabled, or the value
      # did not increase.
      def sample(name : String, value : Int32) : Int32
        return 0 unless enabled?
        return 0 unless @counters[name]?
        prev = @prev_values[name]
        @prev_values[name] = value
        value > prev ? value - prev : 0
      end

      # Enable or disable an individual counter. Returns false if the name is
      # unknown.
      def toggle(name : String, on : Bool) : Bool
        return false unless @counters.has_key?(name)
        @counters[name] = on
        true
      end

      def counter_enabled?(name : String) : Bool
        @counters[name]? || false
      end

      def counter_names : Array(String)
        COUNTERS.keys
      end
    end
  end
end
