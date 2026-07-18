module Hcode
  module LLM
    module TokenCounter
      CHARS_PER_TOKEN = 4

      def self.estimate(text : String) : Int32
        return 0 if text.empty?
        (text.size / CHARS_PER_TOKEN).ceil.to_i32
      end

      def self.estimate(messages : Array(Message)) : Int32
        total = 0
        messages.each do |msg|
          if content = msg.content
            total += estimate(content)
          end
          if tcs = msg.tool_calls
            tcs.each do |tc|
              total += estimate(tc.name) + estimate(tc.arguments)
            end
          end
          total += 4
        end
        total
      end

      # Format a token count in 1024-based units: context sizes are powers
      # of two, so 262144 reads as "256k" rather than "262.1k". Values at
      # or above 100k round to a whole number ("977k"); below that keep one
      # decimal ("22.8k"). Ported from the TS TUI's `formatTokenCount`.
      def self.format_count(n : Int32) : String
        return "0" if n < 0
        return n.to_s if n < 1024
        if n >= 1_048_576
          one_decimal_string(n.to_f64 / 1_048_576) + "M"
        else
          k = n.to_f64 / 1024
          k >= 100 ? "#{k.round.to_i}k" : "#{one_decimal_string(k)}k"
        end
      end

      private def self.one_decimal_string(value : Float64) : String
        rounded = (value * 10).round / 10
        s = rounded.to_s
        s.ends_with?(".0") ? s[0...-2] : s
      end
    end
  end
end
