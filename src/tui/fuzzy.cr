# Fuzzy matching with optimal subsequence scoring.
#
# All query characters must appear in order within the text (subsequence
# match). Among the many ways to align the query to the text, the DP picks
# the alignment that maximizes a quality score so the best matches surface
# first. Scoring signals, tuned similarly to fzf / VS Code fuzzy matching:
#
#   * boundary bonus  — match right after a separator (`-`, `_`, ` `, `.`,
#     `/`, digits, or at the start of the text)
#   * camelCase bonus — match an uppercase letter that follows a lowercase one
#   * consecutive bonus — match adjacent to the previous matched character
#   * gap penalty    — per skipped character between two matches
#
# `Fuzzy.match` returns the score plus the exact matched positions (for
# highlighting); `Fuzzy.filter` keeps only matching items and ranks them by
# score, breaking ties by original order.

module H2code
  module TUI
    module Fuzzy
      # Base score awarded for every matched character.
      MATCH_SCORE = 16
      # Bonus for matching at a word boundary (after a separator or at index 0).
      BONUS_BOUNDARY = 10
      # Bonus for matching the uppercase letter in a camelCase boundary.
      BONUS_CAMEL = 8
      # Bonus when the current match is adjacent to the previous one.
      BONUS_CONSECUTIVE = 18
      # Penalty applied for each character skipped between two matched chars.
      GAP_PENALTY = 2

      # Sentinel meaning "no valid alignment reaches this cell".
      NEG_INF = Int32::MIN // 2

      struct Result
        getter score : Int32
        # Indices into the original text that matched the query, ascending.
        getter positions : Array(Int32)

        def initialize(@score : Int32, @positions : Array(Int32))
        end
      end

      # Returns a `Result` (score + matched positions) when *query* is a
      # subsequence of *text* (case-insensitive), otherwise `nil`.
      def self.match(query : String, text : String) : Result?
        return nil if query.empty?
        return nil if query.size > text.size

        m = query.size
        n = text.size

        down_query = query.downcase
        down_text = text.downcase
        bonus = compute_bonus(text)

        # score[j][i] = best score aligning query[0..j] so that text[i] matches
        # query[j]; NEG_INF when text[i] cannot be the j-th match.
        score = Array.new(m) { Array.new(n, NEG_INF) }
        # back[j][i] = index k < i of the text position matched as query[j-1]
        # in the optimal alignment ending at (j, i); -1 when j == 0.
        back = Array.new(m) { Array.new(n, -1) }

        m.times do |j|
          qj = down_query.char_at(j)
          # i must leave room for the remaining (m-1-j) query chars after it,
          # so the valid range is [j, n-m+j].
          (j..(n - m + j)).each do |i|
            next unless down_text.char_at(i) == qj

            if j == 0
              # First query char: gap is everything skipped before this position.
              score[0][i] = MATCH_SCORE + bonus[i] - GAP_PENALTY * i
              next
            end

            best_k = -1
            best_s = NEG_INF
            (j - 1..i - 1).each do |k|
              prev = score[j - 1][k]
              next if prev <= NEG_INF
              gap = i - k - 1
              consec = k == i - 1 ? BONUS_CONSECUTIVE : 0
              candidate = prev + MATCH_SCORE + bonus[i] + consec - GAP_PENALTY * gap
              if candidate > best_s
                best_s = candidate
                best_k = k
              end
            end
            next unless best_k >= 0
            score[j][i] = best_s
            back[j][i] = best_k
          end
        end

        # Pick the best endpoint in the last row.
        best_end = -1
        best_total = NEG_INF
        ((m - 1)...n).each do |i|
          if score[m - 1][i] > best_total
            best_total = score[m - 1][i]
            best_end = i
          end
        end
        return nil if best_end < 0 || best_total <= NEG_INF

        # Reconstruct matched positions by walking the back pointers.
        positions = [] of Int32
        i = best_end
        (m - 1).downto(0) do |j|
          positions << i
          i = back[j][i]
        end
        positions.reverse!

        Result.new(best_total, positions)
      end

      # True when *query* is a case-insensitive subsequence of *text*.
      def self.matches?(query : String, text : String) : Bool
        return false if query.empty?
        return false if query.size > text.size
        qi = 0
        down = query.downcase
        text.downcase.each_char do |c|
          qi += 1 if c == down.char_at(qi)
          return true if qi >= down.size
        end
        qi >= down.size
      end

      # Filters *items* keeping only those matching *query*, returning their
      # original indices sorted by descending fuzzy score (stable on ties so
      # equal-scoring items keep their input order).
      def self.filter(items : Array(String), query : String) : Array({Int32, Result})
        results = [] of {Int32, Result}
        items.each_with_index do |item, idx|
          if res = match(query, item)
            results << {idx, res}
          end
        end
        # Sort by score desc, then original index asc for stability.
        results.sort_by! { |idx, res| {-res.score, idx} }
        results
      end

      # Bonus weight for matching the character at index *i* of *text*.
      private def self.compute_bonus(text : String) : Array(Int32)
        n = text.size
        arr = Array.new(n, 0)
        n.times do |i|
          if i == 0
            arr[0] = BONUS_BOUNDARY
          else
            prev = text.char_at(i - 1)
            cur = text.char_at(i)
            arr[i] = if separator?(prev)
                       BONUS_BOUNDARY
                     elsif prev.lowercase? && cur.uppercase?
                       BONUS_CAMEL
                     elsif prev.ascii_number? && cur.ascii_letter?
                       BONUS_BOUNDARY
                     else
                       0
                     end
          end
        end
        arr
      end

      private def self.separator?(c : Char) : Bool
        !c.ascii_alphanumeric?
      end
    end
  end
end
