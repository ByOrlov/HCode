module Kimi
  module Prompt
    class Template
      def self.render(template : String, vars : Hash(String, String)) : String
        result = process_conditionals(template, vars)

        vars.each do |key, value|
          result = result.gsub("{{#{key}}}", value)
          result = result.gsub("{{ #{key} }}", value)
        end

        if result =~ /\{\{[^}]+\}\}/
          missing = result.scan(/\{\{([^}]+)\}\}/).map(&.[1].strip).uniq
          raise "Undefined template variables: #{missing.join(", ")}"
        end

        result
      end

      # Process {% if CONDITION %}...{% else %}...{% endif %} blocks.
      # CONDITION can be a bare variable name (true when non-empty) or
      # VAR == "literal" / VAR != "literal".
      # Nested ifs are handled from inside out.
      private def self.process_conditionals(template : String, vars : Hash(String, String)) : String
        result = template

        loop do
          # Match the innermost {% if %}…{% endif %} (no nested if inside).
          # The tempered group (?:(?!\{%\s*(?:if|else|endif)).)*? consumes
          # any character that doesn't start a new control tag.
          match = result.match(
            /\{%\s*if\s+(.+?)\s*%\}((?:(?!\{%\s*(?:if|endif)\s).)*?)\{%\s*endif\s*%\}/m
          )
          break unless match

          condition = match[1]
          body = match[2]

          if_content = body
          else_content = ""

          if em = body.match(/\{%\s*else\s*%\}/m)
            split_pos = em.begin.not_nil!
            if_content = body[0...split_pos]
            else_content = body[em.end.not_nil!..]
          end

          replacement = evaluate_condition(condition, vars) ? if_content : else_content

          range_start = match.begin.not_nil!
          range_end = match.end.not_nil!
          result = result[0...range_start] + replacement + result[range_end..]
        end

        result
      end

      private def self.evaluate_condition(condition : String, vars : Hash(String, String)) : Bool
        if m = condition.match(/^(\w+)\s*==\s*"(.+)"$/)
          vars[m[1]]? == m[2]
        elsif m = condition.match(/^(\w+)\s*!=\s*"(.+)"$/)
          vars[m[1]]? != m[2]
        else
          val = vars[condition.strip]?
          return false if val.nil?
          !val.empty?
        end
      end
    end
  end
end
