module Hcode
  module TUI
    # Terminal column-width measurement, mirroring the layered architecture of
    # the TypeScript `visibleWidth` pipeline in `packages/pi-tui/src/utils.ts`.
    #
    # Layering (each arrow names the TS counterpart):
    #
    #   printable_ascii?  ---- fast path                          isPrintableAscii
    #   extract_ansi_code ---- strip CSI/OSC/APC escapes          extractAnsiCode
    #   grapheme_width    ---- per-cluster width                  graphemeWidth
    #     |- zero_width?        ---- zero-width codepoints        zeroWidthRegex
    #     |- could_be_emoji?    ---- emoji pre-filter             couldBeEmoji + RGI
    #     |- east_asian_width   ---- W/F codepoints               get-east-asian-width
    #   visible_width     ---- main entry: fast path + LRU cache  visibleWidth
    #                          + normalization + grapheme walk
    #   ascii_visible_width - bounded fast ASCII scan             asciiVisibleWidth
    #   truncate_to_width ---- ellipsis truncation                truncateToWidth
    #   slice_with_width  ---- column-range slicing               sliceWithWidth
    #
    # Crystal has no `Intl.Segmenter`, so grapheme clustering is approximated by
    # an index walker over codepoints (base + combining marks, regional-indicator
    # pairs, ZWJ emoji chains) — sufficient for width accounting.
    module CharWidth
      # ------------------------------------------------------------------------
      # Cache (mirrors `widthCache` + `WIDTH_CACHE_SIZE`, FIFO eviction)
      # ------------------------------------------------------------------------
      WIDTH_CACHE_SIZE = 4096
      @@width_cache = {} of String => Int32

      private def self.cache_get(str : String) : Int32?
        @@width_cache[str]?
      end

      private def self.cache_put(str : String, width : Int32) : Nil
        if @@width_cache.size >= WIDTH_CACHE_SIZE
          first_key = @@width_cache.first_key?
          @@width_cache.delete(first_key) if first_key
        end
        @@width_cache[str] = width
      end

      # Test-only: drop the width cache between cases.
      def self.clear_cache : Nil
        @@width_cache.clear
      end

      # ------------------------------------------------------------------------
      # Classification tables
      # ------------------------------------------------------------------------
      # East Asian Wide / Fullwidth ranges (Unicode East Asian Width property W/F).
      WIDE_RANGES = {
        {0x1100_u32, 0x115F_u32},   # Hangul Jamo
        {0x2329_u32, 0x2329_u32},   # LEFT-POINTING ANGLE BRACKET
        {0x232A_u32, 0x232A_u32},   # RIGHT-POINTING ANGLE BRACKET
        {0x2E80_u32, 0x303E_u32},   # CJK radicals, Kangxi, CJK symbols
        {0x3040_u32, 0x33BF_u32},   # Hiragana, Katakana, Bopomofo, Hangul compat
        {0x3400_u32, 0x4DBF_u32},   # CJK Unified Ideographs Extension A
        {0x4E00_u32, 0xA4CF_u32},   # CJK Unified Ideographs, Yi
        {0xA960_u32, 0xA97F_u32},   # Hangul Jamo Extended-A
        {0xAC00_u32, 0xD7A3_u32},   # Hangul Syllables
        {0xF900_u32, 0xFAFF_u32},   # CJK Compatibility Ideographs
        {0xFE10_u32, 0xFE19_u32},   # Vertical forms
        {0xFE30_u32, 0xFE6F_u32},   # CJK Compatibility Forms
        {0xFF00_u32, 0xFF60_u32},   # Fullwidth Forms
        {0xFFE0_u32, 0xFFE6_u32},   # Fullwidth signs
        {0x1F300_u32, 0x1FAFF_u32}, # Symbols & Pictographs + extensions
        {0x20000_u32, 0x3FFFD_u32}, # CJK Unified Ideographs Extensions B+
      }

      # Broad pre-filter for codepoints that *could* be emoji. Mirrors the
      # `couldBeEmoji` block pre-filter in TS — this is NOT a width decision.
      # A codepoint here is width 2 only if it defaults to emoji presentation
      # (`default_emoji_presentation?`) or is followed by U+FE0F (handled in
      # `grapheme_width`); otherwise it falls through to East Asian Width
      # (e.g. ⚠ U+26A0 renders as text by default → width 1).
      EMOJI_RANGES = {
        {0x2600_u32, 0x26FF_u32},   # Miscellaneous Symbols (⚠ U+26A0 text-default, ⚡ U+26A1 emoji-default)
        {0x2700_u32, 0x27BF_u32},   # Dingbats (incl. ✅ U+2705, ❌ U+274C)
        {0x2B50_u32, 0x2B55_u32},   # Stars
        {0x1F000_u32, 0x1F02F_u32}, # Mahjong tiles
        {0x1F0A0_u32, 0x1F0FF_u32}, # Playing cards
        {0x1F100_u32, 0x1F2FF_u32}, # Enclosed alphanumeric supplement
        {0x1F1E6_u32, 0x1F1FF_u32}, # Regional indicator symbols
        {0x1F300_u32, 0x1FAFF_u32}, # Symbols & Pictographs + extensions (smileys, people, ...)
        {0x1FB00_u32, 0x1FBFF_u32}, # Symbols and Pictographs Extended-A
      }

      # BMP codepoints with `Emoji_Presentation=Yes` — they render as emoji
      # (width 2) by default, without needing a U+FE0F selector. Counterpart
      # of the single-codepoint branch of `\p{RGI_Emoji}` in TS `graphemeWidth`.
      # Supplementary pictograph blocks (>= U+1F000) are emoji by default and
      # handled directly in `default_emoji_presentation?`. Notably EXCLUDES ⚠
      # U+26A0 (text presentation) while INCLUDING its neighbor ⚡ U+26A1.
      EMOJI_PRESENTATION_RANGES = {
        {0x231A_u32, 0x231B_u32}, # ⌚ ⌛
        {0x23E9_u32, 0x23EC_u32}, # ⏩..⏬
        {0x23F0_u32, 0x23F0_u32}, # ⏰
        {0x23F3_u32, 0x23F3_u32}, # ⏳
        {0x25FD_u32, 0x25FE_u32}, # ◽ ◾
        {0x2614_u32, 0x2615_u32}, # ☔ ☕
        {0x2648_u32, 0x2653_u32}, # ♈..♓ zodiac
        {0x267F_u32, 0x267F_u32}, # ♿
        {0x2693_u32, 0x2693_u32}, # ⚓
        {0x26A1_u32, 0x26A1_u32}, # ⚡ (⚠ U+26A0 is NOT in this table)
        {0x26AA_u32, 0x26AB_u32}, # ⚪ ⚫
        {0x26BD_u32, 0x26BE_u32}, # ⚽ ⚾
        {0x26C4_u32, 0x26C5_u32}, # ⛄ ⛅
        {0x26CE_u32, 0x26CE_u32}, # ⛎
        {0x26D4_u32, 0x26D4_u32}, # ⛔
        {0x26EA_u32, 0x26EA_u32}, # ⛪
        {0x26F2_u32, 0x26F3_u32}, # ⛲ ⛳
        {0x26F5_u32, 0x26F5_u32}, # ⛵
        {0x26FA_u32, 0x26FA_u32}, # ⛺
        {0x26FD_u32, 0x26FD_u32}, # ⛽
        {0x2705_u32, 0x2705_u32}, # ✅
        {0x270A_u32, 0x270B_u32}, # ✊ ✋
        {0x2728_u32, 0x2728_u32}, # ✨
        {0x274C_u32, 0x274C_u32}, # ❌
        {0x274E_u32, 0x274E_u32}, # ❎
        {0x2753_u32, 0x2755_u32}, # ❓ ❔ ❕
        {0x2757_u32, 0x2757_u32}, # ❗
        {0x2795_u32, 0x2797_u32}, # ➕ ➖ ➗
        {0x27B0_u32, 0x27B0_u32}, # ➰
        {0x27BF_u32, 0x27BF_u32}, # ➿
        {0x2B1B_u32, 0x2B1C_u32}, # ⬛ ⬜
        {0x2B50_u32, 0x2B50_u32}, # ⭐
        {0x2B55_u32, 0x2B55_u32}, # ⭕
      }

      # Combining / formatting codepoints that contribute no advance width
      # (counterpart of `zeroWidthRegex`). Note: ZWJ (U+200D) is handled
      # specially by the grapheme walker, so it is excluded here.
      ZERO_WIDTH_RANGES = {
        {0x0300_u32, 0x036F_u32}, # Combining Diacritical Marks
        {0x0483_u32, 0x0489_u32},
        {0x0591_u32, 0x05BD_u32},
        {0x05BF_u32, 0x05BF_u32},
        {0x05C1_u32, 0x05C2_u32},
        {0x05C4_u32, 0x05C5_u32},
        {0x05C7_u32, 0x05C7_u32},
        {0x0600_u32, 0x0605_u32},
        {0x0610_u32, 0x061A_u32},
        {0x064B_u32, 0x065F_u32},
        {0x0670_u32, 0x0670_u32},
        {0x06D6_u32, 0x06DC_u32},
        {0x06DF_u32, 0x06E4_u32},
        {0x06E7_u32, 0x06E8_u32},
        {0x06EA_u32, 0x06ED_u32},
        {0x070F_u32, 0x070F_u32},
        {0x0711_u32, 0x0711_u32},
        {0x0730_u32, 0x074A_u32},
        {0x07A6_u32, 0x07B0_u32},
        {0x07EB_u32, 0x07F3_u32},
        {0x0816_u32, 0x0819_u32},
        {0x081B_u32, 0x0823_u32},
        {0x0825_u32, 0x0827_u32},
        {0x0829_u32, 0x082D_u32},
        {0x0859_u32, 0x085B_u32},
        {0x08D3_u32, 0x08E1_u32},
        {0x08E3_u32, 0x0902_u32},
        {0x093A_u32, 0x093A_u32},
        {0x093C_u32, 0x093C_u32},
        {0x0941_u32, 0x0948_u32},
        {0x1AB0_u32, 0x1AFF_u32}, # Combining Diacritical Marks Extended
        {0x1DC0_u32, 0x1DFF_u32}, # Combining Diacritical Marks Supplement
        {0x200B_u32, 0x200C_u32}, # Zero-width space, ZWNJ (ZWJ handled in walker)
        {0x200E_u32, 0x200F_u32}, # LRM/RLM
        {0x202A_u32, 0x202E_u32}, # Bidi controls
        {0x2060_u32, 0x2064_u32},
        {0x2066_u32, 0x206F_u32},
        {0x20D0_u32, 0x20FF_u32}, # Combining Diacritical Marks for Symbols
        {0xFE00_u32, 0xFE0F_u32}, # Variation Selectors (VS1-VS16)
        {0xFE20_u32, 0xFE2F_u32}, # Combining Half Marks
        {0xFEFF_u32, 0xFEFF_u32}, # Zero-width no-break space (BOM)
      }

      # CJK script ranges for word-breaking (counterpart of `cjkBreakRegex`).
      CJK_SCRIPT_RANGES = {
        {0x1100_u32, 0x11FF_u32}, # Hangul Jamo
        {0x2E80_u32, 0x2EFF_u32}, # CJK Radicals Supplement
        {0x2F00_u32, 0x2FDF_u32}, # Kangxi Radicals
        {0x3000_u32, 0x303F_u32}, # CJK Symbols and Punctuation
        {0x3040_u32, 0x309F_u32}, # Hiragana
        {0x30A0_u32, 0x30FF_u32}, # Katakana
        {0x3100_u32, 0x312F_u32}, # Bopomofo
        {0x3130_u32, 0x318F_u32}, # Hangul Compatibility Jamo
        {0x3400_u32, 0x4DBF_u32}, # CJK Unified Ideographs Extension A
        {0x4E00_u32, 0x9FFF_u32}, # CJK Unified Ideographs
        {0xAC00_u32, 0xD7A3_u32}, # Hangul Syllables
        {0xF900_u32, 0xFAFF_u32}, # CJK Compatibility Ideographs
        {0xFF00_u32, 0xFFEF_u32}, # Fullwidth Forms
      }

      private def self.in_range?(cp : UInt32, ranges) : Bool
        ranges.each do |(lo, hi)|
          return true if cp >= lo && cp <= hi
        end
        false
      end

      # ------------------------------------------------------------------------
      # Classification predicates (mirror couldBeEmoji / zeroWidthRegex test)
      # ------------------------------------------------------------------------

      # Counterpart of `couldBeEmoji` heuristic (broad block pre-filter).
      def self.could_be_emoji?(cp : UInt32) : Bool
        in_range?(cp, EMOJI_RANGES)
      end

      # Whether a codepoint renders as emoji (width 2) by default presentation,
      # i.e. `Emoji_Presentation=Yes`. Counterpart of the single-codepoint RGI
      # gate applied by `rgiEmojiRegex.test(segment)` in TS `graphemeWidth` when
      # the segment has no VS16 selector. BMP coverage is enumerated explicitly
      # (see EMOJI_PRESENTATION_RANGES); supplementary pictograph blocks
      # (>= U+1F000) are emoji by default.
      private def self.default_emoji_presentation?(cp : UInt32) : Bool
        return true if cp >= 0x1F000
        in_range?(cp, EMOJI_PRESENTATION_RANGES)
      end

      # Counterpart of `zeroWidthRegex.test`. Excludes ZWJ (U+200D), which is
      # consumed explicitly by the grapheme walker.
      def self.zero_width?(cp : UInt32) : Bool
        return true if cp == 0x200D
        in_range?(cp, ZERO_WIDTH_RANGES)
      end

      private def self.combining_mark?(cp : UInt32) : Bool
        return false if cp == 0x200D
        in_range?(cp, ZERO_WIDTH_RANGES)
      end

      private def self.regional_indicator?(cp : UInt32) : Bool
        cp >= 0x1F1E6 && cp <= 0x1F1FF
      end

      # Counterpart of `cjkBreakRegex.test(segment)` for word-breaking.
      def self.cjk_break?(cp : UInt32) : Bool
        in_range?(cp, CJK_SCRIPT_RANGES)
      end

      # Counterpart of `eastAsianWidth(cp)` from `get-east-asian-width`.
      private def self.east_asian_width(cp : UInt32) : Int32
        in_range?(cp, WIDE_RANGES) ? 2 : 1
      end

      # ------------------------------------------------------------------------
      # Per-codepoint / per-grapheme width (mirror graphemeWidth)
      # ------------------------------------------------------------------------

      # Width of a single base codepoint. Counterpart of the body of
      # `graphemeWidth` for a single codepoint cluster: tab→3, control/zero→0,
      # emoji/regional indicator→2, East Asian Wide/Fullwidth→2, else 1.
      def self.codepoint_width(cp : UInt32) : Int32
        return 3 if cp == 0x09 # \t
        return 0 if cp < 0x20 || cp == 0x7F
        return 0 if in_range?(cp, ZERO_WIDTH_RANGES)
        return 2 if regional_indicator?(cp)
        # Width 2 only when the codepoint defaults to emoji presentation. BMP
        # chars in emoji blocks that default to TEXT (e.g. ⚠ U+26A0) fall
        # through to East Asian Width (Ambiguous -> 1), matching the RGI gate
        # in TS `graphemeWidth`. VS16 promotion is handled in `grapheme_width`.
        return 2 if could_be_emoji?(cp) && default_emoji_presentation?(cp)
        east_asian_width(cp)
      end

      # Convenience overload for `Char`.
      def self.codepoint_width(c : Char) : Int32
        codepoint_width(c.ord.to_u32)
      end

      # Width of a base codepoint followed by a trailing fullwidth/halfwidth
      # tail within the same grapheme cluster (mirrors the trailing-forms loop
      # in `graphemeWidth`). `tail` is the list of codepoints after the base.
      private def self.grapheme_width(base : UInt32, tail : Array(UInt32)) : Int32
        w = codepoint_width(base)
        # VS16 (U+FE0F) after an emoji-capable base that defaults to TEXT
        # presentation (e.g. ⚠ -> ⚠️) promotes the cluster to emoji width 2.
        # Mirrors `rgiEmojiRegex` matching `<base>\uFE0F` as an RGI Emoji.
        if w < 2 && could_be_emoji?(base) && tail.includes?(0xFE0F_u32)
          w = 2
        end
        tail.each do |c|
          if c >= 0xFF00 && c <= 0xFFEF
            w += east_asian_width(c)
          elsif c == 0x0E33 || c == 0x0EB3 # Thai/Lao AM vowels segment with base
            w += 1
          end
        end
        w
      end

      # ------------------------------------------------------------------------
      # Grapheme-cluster width walk (approximates `Intl.Segmenter` + sum of
      # `graphemeWidth`). Operates on an ANSI-free codepoint array.
      # ------------------------------------------------------------------------
      private def self.sum_grapheme_width(cps : Array(UInt32)) : Int32
        width = 0
        i = 0
        n = cps.size
        while i < n
          cp = cps[i]

          # CR LF
          if cp == 0x0D && i + 1 < n && cps[i + 1] == 0x0A
            i += 2
            next
          end

          # Regional indicator pairs (flag emoji): each pair = one cluster = 2.
          if regional_indicator?(cp)
            j = i
            while j < n && regional_indicator?(cps[j])
              j += 1
            end
            count = j - i
            width += 2 * ((count + 1) // 2)
            i = j
            next
          end

          # Base + trailing combining marks (and ZWJ emoji chains).
          tail = [] of UInt32
          k = i + 1
          # consume plain combining marks attached to this base
          while k < n && combining_mark?(cps[k])
            tail << cps[k]
            k += 1
          end
          # ZWJ + emoji extension keeps the cluster at the base's width
          while k < n && cps[k] == 0x200D && k + 1 < n && could_be_emoji?(cps[k + 1])
            tail << cps[k]     # ZWJ
            tail << cps[k + 1] # joined emoji (no extra width)
            k += 2
            while k < n && combining_mark?(cps[k])
              tail << cps[k]
              k += 1
            end
          end

          width += grapheme_width(cp, tail)
          i = k
        end
        width
      end

      # ------------------------------------------------------------------------
      # ANSI escape extraction (mirror extractAnsiCode: CSI / OSC / APC)
      # ------------------------------------------------------------------------
      record AnsiCode, code : String, length : Int32

      # Extracts a supported ANSI/OSC/APC escape sequence beginning at `pos`.
      # Returns `nil` if there is no well-formed sequence there.
      def self.extract_ansi_code(str : String, pos : Int32) : AnsiCode?
        return nil if pos >= str.bytesize
        return nil unless str.byte_at(pos) == 0x1b # ESC

        bytes = str.to_slice
        return nil if pos + 1 >= bytes.size
        next_b = bytes[pos + 1]

        # CSI: ESC [ ... <final>   (final in 0x40..0x7e, e.g. m G K H J)
        if next_b == 0x5B # '['
          j = pos + 2
          while j < bytes.size
            b = bytes[j]
            return AnsiCode.new(str.byte_slice(pos, j + 1 - pos), j + 1 - pos) if b >= 0x40 && b <= 0x7e
            j += 1
          end
          return nil
        end

        # OSC: ESC ] ... BEL | ST (ESC \)
        if next_b == 0x5D # ']'
          j = pos + 2
          while j < bytes.size
            if bytes[j] == 0x07 # BEL
              return AnsiCode.new(str.byte_slice(pos, j + 1 - pos), j + 1 - pos)
            end
            if bytes[j] == 0x1b && j + 1 < bytes.size && bytes[j + 1] == 0x5c # ST (ESC \)
              return AnsiCode.new(str.byte_slice(pos, j + 2 - pos), j + 2 - pos)
            end
            j += 1
          end
          return nil
        end

        # APC: ESC _ ... BEL | ST (ESC \)
        if next_b == 0x5F # '_'
          j = pos + 2
          while j < bytes.size
            if bytes[j] == 0x07
              return AnsiCode.new(str.byte_slice(pos, j + 1 - pos), j + 1 - pos)
            end
            if bytes[j] == 0x1b && j + 1 < bytes.size && bytes[j + 1] == 0x5c
              return AnsiCode.new(str.byte_slice(pos, j + 2 - pos), j + 2 - pos)
            end
            j += 1
          end
          return nil
        end

        nil
      end

      private def self.utf8_byte_length(leading_byte : UInt8) : Int32
        return 1 if leading_byte < 0x80
        return 2 if leading_byte < 0xE0
        return 3 if leading_byte < 0xF0
        4
      end

      def self.strip_ansi(str : String) : String
        return str unless str.includes?('\e')
        bytes = str.to_slice
        out_str = IO::Memory.new
        i = 0
        while i < bytes.size
          if bytes[i] == 0x1b
            ansi = extract_ansi_code(str, i)
            if ansi
              i += ansi.length
              next
            end
          end
          char_len = utf8_byte_length(bytes[i])
          out_str.write(bytes[i, char_len])
          i += char_len
        end
        out_str.to_s
      end

      # ------------------------------------------------------------------------
      # Printable ASCII fast path (mirror isPrintableAscii)
      # ------------------------------------------------------------------------
      private def self.printable_ascii?(str : String) : Bool
        str.each_byte do |b|
          return false if b < 0x20 || b > 0x7e
        end
        true
      end

      # ------------------------------------------------------------------------
      # Main entry (mirror visibleWidth)
      # ------------------------------------------------------------------------
      # Visible terminal width of `str` in columns. Skips ANSI/OSC/APC escapes,
      # expands tabs to 3 columns, and weighs grapheme clusters (emoji and East
      # Asian Wide/Fullwidth count as 2). Results are cached (FIFO, 4096 slots).
      def self.visible_width(str : String) : Int32
        return 0 if str.empty?

        # Fast path: pure printable ASCII.
        return str.size if printable_ascii?(str)

        # Cache lookup keyed by the original string (with escapes).
        if cached = cache_get(str)
          return cached
        end

        # Normalize: tabs -> 3 spaces, then strip escape sequences.
        clean = str.includes?('\t') ? str.gsub('\t', "   ") : str
        clean = strip_ansi(clean) if clean.includes?('\e')

        width = sum_grapheme_width(clean.codepoints.map(&.to_u32))

        cache_put(str, width)
        width
      end

      # ------------------------------------------------------------------------
      # Bounded fast ASCII scan (mirror asciiVisibleWidth)
      # ------------------------------------------------------------------------
      # Fast visible-width scan for lines whose printable content is plain ASCII,
      # skipping ANSI escape sequences. Returns the visible width, or `nil` when
      # the line contains control characters or non-ASCII content (caller should
      # fall back to `visible_width`). Early-exits as soon as width exceeds
      # `limit`, returning the partial count.
      def self.ascii_visible_width(line : String, limit : Int32) : Int32?
        width = 0
        i = 0
        bytes = line.to_slice
        while i < bytes.size
          if bytes[i] == 0x1b
            ansi = extract_ansi_code(line, i)
            return nil unless ansi
            i += ansi.length
            next
          end
          code = bytes[i].to_u32
          return nil if code < 0x20 || code > 0x7e
          width += 1
          return width if width > limit
          i += 1
        end
        width
      end

      # ------------------------------------------------------------------------
      # Truncate by display width (mirror truncateToWidth)
      # ------------------------------------------------------------------------
      private def self.finalize_truncated(prefix : String, prefix_w : Int32,
                                          ellipsis : String, ellipsis_w : Int32,
                                          max_width : Int32, pad : Bool) : String
        reset = ANSI.reset
        result = ellipsis.empty? ? "#{prefix}#{reset}" : "#{prefix}#{reset}#{ellipsis}#{reset}"
        pad ? result + (" " * {0, max_width - (prefix_w + ellipsis_w)}.max) : result
      end

      private def self.truncate_fragment(text : String, max_width : Int32) : {String, Int32}
        return {"", 0} if max_width <= 0 || text.empty?

        if printable_ascii?(text)
          clipped = text[0...max_width]
          return {clipped, clipped.size}
        end

        result = IO::Memory.new
        width = 0
        cps = text.codepoints.map(&.to_u32)
        i = 0
        n = cps.size
        while i < n
          cp = cps[i]
          cw = codepoint_width(cp)
          # Consume trailing combining marks as part of this grapheme.
          k = i + 1
          while k < n && combining_mark?(cps[k])
            cw += 0
            k += 1
          end
          break if width + cw > max_width
          result << cps[i...k].map(&.chr).join
          width += cw
          i = k
        end
        {result.to_s, width}
      end

      # Truncate `text` to `max_width` columns, appending `ellipsis` and optional
      # right-padding. Counterpart of `truncateToWidth`.
      def self.truncate_to_width(text : String, max_width : Int32,
                                 ellipsis : String = "...", pad : Bool = false) : String
        return "" if max_width <= 0
        return pad ? " " * max_width : "" if text.empty?

        ellipsis_w = visible_width(ellipsis)
        if ellipsis_w >= max_width
          text_w = visible_width(text)
          return pad ? text + (" " * {0, max_width - text_w}.max) : text if text_w <= max_width

          clipped = truncate_fragment(ellipsis, max_width)
          return finalize_truncated("", 0, clipped[0], clipped[1], max_width, pad) if clipped[1] == 0
          return finalize_truncated("", 0, clipped[0], clipped[1], max_width, pad)
        end

        if printable_ascii?(text)
          return pad ? text + (" " * {0, max_width - text.size}.max) : text if text.size <= max_width
          target = max_width - ellipsis_w
          return finalize_truncated(text[0...target], target, ellipsis, ellipsis_w, max_width, pad)
        end

        # General path: walk graphemes, keep a contiguous prefix within budget.
        target = max_width - ellipsis_w
        result = IO::Memory.new
        kept_w = 0
        visible_so_far = 0
        overflowed = false
        cps = text.codepoints.map(&.to_u32)
        i = 0
        n = cps.size
        while i < n
          cp = cps[i]
          k = i + 1
          while k < n && combining_mark?(cps[k])
            k += 1
          end
          w = grapheme_width(cp, cps[(i + 1)...k])

          if kept_w + w <= target
            result << cps[i...k].map(&.chr).join
            kept_w += w
          end
          visible_so_far += w
          if visible_so_far > max_width
            overflowed = true
            break
          end
          i = k
        end

        return pad ? text + (" " * {0, max_width - visible_width(text)}.max) : text unless overflowed

        finalize_truncated(result.to_s, kept_w, ellipsis, ellipsis_w, max_width, pad)
      end

      # ------------------------------------------------------------------------
      # Column slicing (mirror sliceWithWidth / sliceByColumn)
      # ------------------------------------------------------------------------
      record SliceResult, text : String, width : Int32

      # Slice the columns [`start_col`, `start_col + length`) from `line`,
      # preserving ANSI codes that fall inside the range. Counterpart of
      # `sliceWithWidth`.
      def self.slice_with_width(line : String, start_col : Int32, length : Int32,
                                strict : Bool = false) : SliceResult
        return SliceResult.new("", 0) if length <= 0
        end_col = start_col + length

        result = IO::Memory.new
        result_w = 0
        current_col = 0
        pending_ansi = IO::Memory.new

        bytes = line.to_slice
        i = 0
        bsize = bytes.size
        while i < bsize
          if bytes[i] == 0x1b
            ansi = extract_ansi_code(line, i)
            if ansi
              if current_col >= start_col && current_col < end_col
                result << ansi.code
              elsif current_col < start_col
                pending_ansi << ansi.code
              end
              i += ansi.length
              next
            end
          end

          # Consume a run of non-escape chars, then walk grapheme clusters.
          run_end = i
          while run_end < bsize && !(bytes[run_end] == 0x1b && extract_ansi_code(line, run_end))
            run_end += utf8_byte_length(bytes[run_end])
          end
          cps = line.byte_slice(i, run_end - i).codepoints.map(&.to_u32)
          ci = 0
          cn = cps.size
          while ci < cn
            cp = cps[ci]
            ck = ci + 1
            while ck < cn && combining_mark?(cps[ck])
              ck += 1
            end
            w = grapheme_width(cp, cps[(ci + 1)...ck])
            in_range = current_col >= start_col && current_col < end_col
            fits = !strict || current_col + w <= end_col
            if in_range && fits
              unless pending_ansi.empty?
                result << pending_ansi.to_s
                pending_ansi.clear
              end
              result << cps[ci...ck].map(&.chr).join
              result_w += w
            end
            current_col += w
            break if current_col >= end_col
            ci = ck
          end

          i = run_end
          break if current_col >= end_col
        end

        SliceResult.new(result.to_s, result_w)
      end

      # Convenience: return just the sliced text. Counterpart of `sliceByColumn`.
      def self.slice_by_column(line : String, start_col : Int32, length : Int32,
                               strict : Bool = false) : String
        slice_with_width(line, start_col, length, strict).text
      end
    end
  end
end
