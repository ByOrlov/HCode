module H2code
  module TUI
    # Line-level diff via LCS (longest common subsequence), plus intra-line
    # word highlighting: when a deleted line is immediately followed by an
    # added line, the common prefix/suffix is dimmed and only the changed
    # middle spans are emphasized. This mirrors the TS `diff-preview.ts`
    # shape (context/add/delete) and adds the word-level polish.
    module DiffComputer
      enum Kind
        Context
        Add
        Delete
      end

      struct DiffLine
        getter kind : Kind
        getter content : String
        # For a delete+add pair, the highlighted segments (only set on the
        # Add line of such a pair). Empty otherwise.
        getter highlight : HighlightSpan?

        def initialize(@kind : Kind, @content : String, @highlight : HighlightSpan? = nil)
        end
      end

      # A span within a line that changed: [start, length) in the line's
      # content, used by the renderer to emphasize the changed words.
      struct HighlightSpan
        getter start : Int32
        getter length : Int32

        def initialize(@start : Int32, @length : Int32)
        end
      end

      # Compute a line-level diff between `old_text` and `new_text` using LCS.
      # Returns only the changed lines (add/delete), plus any add line that
      # is paired with a preceding delete carries word-level highlight info.
      def self.changed_lines(old_text : String, new_text : String) : Array(DiffLine)
        old_lines = old_text.split('\n')
        new_lines = new_text.split('\n')

        # LCS DP table.
        m = old_lines.size
        n = new_lines.size
        dp = Array.new(m + 1) { Array.new(n + 1, 0) }
        (1..m).each do |i|
          (1..n).each do |j|
            dp[i][j] = old_lines[i - 1] == new_lines[j - 1] ? dp[i - 1][j - 1] + 1 : Math.max(dp[i - 1][j], dp[i][j - 1])
          end
        end

        # Backtrack to build the diff (reversed, then reverse).
        reversed = [] of DiffLine
        i = m
        j = n
        while i > 0 || j > 0
          if i > 0 && j > 0 && old_lines[i - 1] == new_lines[j - 1]
            reversed << DiffLine.new(Kind::Context, new_lines[j - 1])
            i -= 1
            j -= 1
          elsif j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])
            reversed << DiffLine.new(Kind::Add, new_lines[j - 1])
            j -= 1
          else
            reversed << DiffLine.new(Kind::Delete, old_lines[i - 1])
            i -= 1
          end
        end

        result = reversed.reverse

        # Pair adjacent delete+add lines and compute word-level highlight for
        # the add line (the changed region between common prefix/suffix).
        paired = [] of DiffLine
        k = 0
        while k < result.size
          if result[k].kind.delete? && result[k + 1]?.try(&.kind.add?)
            del = result[k].content
            add = result[k + 1].content
            span = changed_span(del, add)
            paired << result[k]
            paired << DiffLine.new(Kind::Add, add, span)
            k += 2
          else
            paired << result[k]
            k += 1
          end
        end

        # Drop context lines — the caller (edit diff) only shows changes.
        paired.reject(&.kind.context?)
      end

      # Find the first changed span between two lines: the region between the
      # longest common prefix and suffix. Returns nil if they are identical
      # or one is a prefix/suffix of the other (no isolated middle change).
      private def self.changed_span(a : String, b : String) : HighlightSpan?
        return nil if a == b
        return nil if a.empty? || b.empty?

        # Common prefix length (in characters).
        prefix = 0
        max_prefix = Math.min(a.size, b.size)
        while prefix < max_prefix && a[prefix]? == b[prefix]?
          prefix += 1
        end

        # Common suffix length, not overlapping the prefix.
        suffix = 0
        max_suffix = Math.min(a.size - prefix, b.size - prefix)
        while suffix < max_suffix &&
              a[a.size - 1 - suffix]? == b[b.size - 1 - suffix]?
          suffix += 1
        end

        return nil if suffix == 0 && prefix == 0

        start = prefix
        length = b.size - prefix - suffix
        length = 0 if length < 0
        HighlightSpan.new(start, length)
      end
    end
  end
end
