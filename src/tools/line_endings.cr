module H2code
  module Tools
    enum LineEndingStyle
      Lf
      Crlf
      Mixed

      def crlf? : Bool
        self == LineEndingStyle::Crlf
      end

      def mixed? : Bool
        self == LineEndingStyle::Mixed
      end
    end

    # Normalized view of a file's text as seen by the model: CRLF line
    # endings are folded to LF so an LLM that always emits LF in
    # `oldString` / `newString` can match against a pure-CRLF file.
    # `materialize` restores the on-disk style when writing back.
    record ModelTextView, text : String, line_ending_style : LineEndingStyle

    module LineEndings
      # Classify a raw file body by its line-ending mix:
      #   lf    — only LF
      #   crlf  — only CRLF
      #   mixed — lone CR, or a blend of CRLF and LF
      def self.detect_style(raw : String) : LineEndingStyle
        has_crlf = false
        has_lf = false
        has_lone_cr = false

        i = 0
        size = raw.bytesize
        bytes = raw.to_slice
        while i < size
          c = bytes[i]
          if c == '\r'.ord
            if i + 1 < size && bytes[i + 1] == '\n'.ord
              has_crlf = true
              i += 1
            else
              has_lone_cr = true
            end
          elsif c == '\n'.ord
            has_lf = true
          end
          i += 1
        end

        return LineEndingStyle::Mixed if has_lone_cr || (has_crlf && has_lf)
        return LineEndingStyle::Crlf if has_crlf
        LineEndingStyle::Lf
      end

      # Produce the model-facing text: for pure CRLF files, collapse
      # "\r\n" to "\n"; everything else is returned verbatim so mixed
      # endings (and lone "\r") stay visible for the caller to handle.
      def self.to_model_view(raw : String) : ModelTextView
        style = detect_style(raw)
        return ModelTextView.new(raw, style) unless style.crlf?
        ModelTextView.new(raw.gsub("\r\n", "\n"), style)
      end

      # Write back in the original style: for pure CRLF files, turn
      # every LF into CRLF (after first normalizing any stray CRLF).
      def self.materialize(text : String, style : LineEndingStyle) : String
        return text unless style.crlf?
        text.gsub("\r\n", "\n").gsub("\n", "\r\n")
      end

      # For CRLF bodies, the trailing CR is folded to LF by `to_model_view`,
      # so `raw_content` is already clean. For pure-CRLF files where the
      # caller passes the raw line (still ending in `\r`), strip that trailing
      # `\r`. This mirrors JS `stripTrailingLf`.
      def self.strip_trailing_cr(line : String) : String
        line.ends_with?('\r') ? line[0...-1] : line
      end

      # For `mixed` files, render lone CRs visibly so the model has a chance
      # to spot them. Mirrors JS `makeCarriageReturnsVisible`.
      def self.make_cr_visible(line : String) : String
        line.gsub('\r', "\\r")
      end
    end
  end
end
