module Hcode
  module TUI
    class Markdown
      @theme : Theme

      def initialize(@theme : Theme = Theme.dark)
      end

      # ------------------------------------------------------------------------
      # Public entry point
      # ------------------------------------------------------------------------

      def render(text : String, width : Int32) : Array(String)
        lines = [] of String
        raw_lines = text.split('\n')

        state = RenderState.new
        content_width = {1, width - 2}.max # account for default 2-space indent

        raw_lines.each_with_index do |line, idx|
          # --- code fence ---
          if line.strip.starts_with?("```") || (line.strip.size >= 3 && line.strip.starts_with?("```"))
            if state.in_code_block?
              flush_table(state, content_width, lines)
              state.in_code_block = false
              state.code_lang = ""
              lines << "#{ANSI.color(@theme.colors.muted, nil)}  ──────────────#{ANSI.reset}"
            else
              flush_table(state, content_width, lines)
              state.in_code_block = true
              state.code_lang = line.strip[3..].strip
              lines << "#{ANSI.color(@theme.colors.muted, nil)}  #{state.code_lang} ────────────#{ANSI.reset}"
            end
            state.last_block = :code
            next
          end

          if state.in_code_block?
            lines << highlight_code(line, state.code_lang)
            next
          end

          # --- table ---
          if table_line?(line)
            state.table_rows << line
            state.in_table = true
            state.last_block = :table
            next
          elsif state.in_table?
            flush_table(state, content_width, lines)
          end

          stripped = line.strip

          # --- blank ---
          if stripped.empty?
            emit_separator(lines, state)
            state.last_block = :blank
            next
          end

          # --- horizontal rule ---
          if horizontal_rule?(stripped)
            emit_separator(lines, state)
            hr_width = {width, 80}.min
            lines << "#{ANSI.color(@theme.colors.border, nil)}#{"─" * hr_width}#{ANSI.reset}"
            state.last_block = :hr
            next
          end

          # --- heading ---
          if m = stripped.match(Regex.new(%q(\A(#{1,6})\s+(.*))))
            emit_separator(lines, state)
            level = m[1].size
            content = m[2]
            render_heading(level, content, content_width, lines)
            state.last_block = :heading
            next
          end

          # --- blockquote ---
          if stripped.starts_with?(">")
            emit_separator(lines, state) unless state.last_block == :blockquote
            content = stripped.lchop('>').strip
            styled = render_inline(content)
            wrapped = wrap_line("  #{ANSI.color(@theme.colors.dim, nil)}#{ANSI.italic}  │ #{styled}#{ANSI.reset}", width)
            wrapped.each { |l| lines << l }
            state.last_block = :blockquote
            next
          end

          # --- list item (unordered, ordered, task) ---
          if m = stripped.match(/\A(\s*)([-*+]\s+|\d+\.\s+)(.*)/)
            emit_separator(lines, state) unless state.last_block == :list
            leading = line[/\A(\s*)/, 1].size
            depth = leading // 2
            marker = m[2]
            rest = m[3]

            # task list?
            if task = rest.match(/\A\[([ xX])\]\s+(.*)/)
              checked = task[1].downcase == "x"
              task_text = task[2]
              box = checked ? "[x]" : "[ ]"
              box_color = checked ? @theme.colors.success : @theme.colors.dim
              indent_str = "    " * depth
              prefix = "#{indent_str}#{ANSI.color(box_color, nil)}#{box}#{ANSI.reset} "
              item_width = {1, content_width - visible_width(prefix)}.max
              styled = render_inline(task_text)
              wrapped = wrap_line(styled, item_width)
              wrapped.each_with_index do |wl, i|
                p = i == 0 ? prefix : "#{indent_str}   "
                lines << "#{p}#{wl}"
              end
            else
              indent_str = "    " * depth
              if marker =~ /\d/
                num = marker.strip
                marker_text = "  #{num} "
              else
                marker_text = "  • "
              end
              prefix = "#{indent_str}#{ANSI.color(@theme.colors.accent, nil)}#{marker_text}#{ANSI.reset}"
              cont_prefix = "#{indent_str}#{" " * marker_text.size}"
              item_width = {1, content_width - visible_width(prefix)}.max
              styled = render_inline(rest)
              wrapped = wrap_line(styled, item_width)
              wrapped.each_with_index do |wl, i|
                lines << (i == 0 ? prefix : cont_prefix) + wl
              end
            end
            state.last_block = :list
            next
          end

          # --- paragraph ---
          emit_separator(lines, state) unless state.last_block == :paragraph
          styled = render_inline(line)
          para_width = {1, width - 2}.max
          wrapped = wrap_line(styled, para_width)
          wrapped.each { |l| lines << "  #{l}" }
          state.last_block = :paragraph
        end

        # Flush any pending table at end of input (streaming safety)
        flush_table(state, content_width, lines) if state.in_table?

        lines
      end

      private def render_heading(level : Int32, content : String, content_width : Int32, lines : Array(String))
        color = case level
                when 1 then @theme.colors.accent
                when 2 then @theme.colors.info
                else        @theme.colors.muted
                end
        indent = case level
                 when 1 then "  "
                 when 2 then "  "
                 else        "    "
                 end
        styled_content = render_inline(content)

        case level
        when 1
          full = "#{ANSI.color(color, nil)}#{ANSI.bold}#{ANSI.underline}#{styled_content}#{ANSI.reset}"
        when 2
          full = "#{ANSI.color(color, nil)}#{ANSI.bold}#{styled_content}#{ANSI.reset}"
        else
          hash_prefix = "#" * level + " "
          full = "#{ANSI.color(color, nil)}#{ANSI.bold}#{hash_prefix}#{styled_content}#{ANSI.reset}"
        end

        head_width = {1, content_width - visible_width(indent) + 2}.max
        wrapped = wrap_line(full, head_width)
        wrapped.each { |l| lines << "#{indent}#{l}" }
      end

      private def emit_separator(lines : Array(String), state : RenderState)
        return if lines.empty?
        return if lines.last == ""
        return if state.last_block == :blank
        lines << ""
      end

      # ------------------------------------------------------------------------
      # Table rendering
      # ------------------------------------------------------------------------

      private def table_line?(line : String) : Bool
        stripped = line.strip
        return false unless stripped.starts_with?("|") || stripped.ends_with?("|")
        # Separator row: |---|---|
        return true if stripped.match(/\A\|?[-\s:]+(\|[-\s:]+)+\|?\z/)
        # Data row: | a | b |
        stripped.count('|') >= 1
      end

      private def flush_table(state : RenderState, width : Int32, lines : Array(String))
        return unless state.table_rows.size > 0
        rows = state.table_rows
        state.table_rows = [] of String
        state.in_table = false

        parsed = rows.map { |r| parse_table_row(r) }

        sep_idx = parsed.index { |cells| cells.all? { |c| c.strip.match(/\A:?-{2,}:?\z/) || c.strip.match(/\A:?-+:?\z/) } }

        # GFM: a table requires a header row followed by a delimiter row.
        # Without a delimiter (e.g. a lone line like `arr.each do | o |` that
        # merely ends with `|`), this is plain text — render it as such so it
        # is not boxed into a stray Unicode table.
        unless sep_idx
          raw_text = rows.join('\n')
          wrap_line(raw_text, {1, width}.max).each { |l| lines << "  #{l}" }
          return lines
        end

        header = parsed[0]
        data_rows = parsed[(sep_idx + 1)..]

        header = header || [] of String
        return if header.empty?

        num_cols = header.size

        header = header.map { |cell| render_inline(cell.strip) }
        data_rows = data_rows.map { |row| row.map { |cell| render_inline(cell.strip) } }

        border_overhead = 3 * num_cols + 1
        available_for_cells = width - border_overhead

        if available_for_cells < num_cols
          raw_text = rows.join('\n')
          wrap_line(raw_text, {1, width}.max).each { |l| lines << "  #{l}" }
          return lines
        end

        max_unbroken_word_width = 30

        natural_widths = Array.new(num_cols, 0)
        min_word_widths = Array.new(num_cols, 1)
        all_rows = [header] + data_rows
        all_rows.each do |row|
          row.each_with_index do |cell, i|
            next if i >= num_cols
            text = cell.strip
            natural_widths[i] = {natural_widths[i], visible_width(text)}.max
            min_word_widths[i] = {min_word_widths[i], get_longest_word_width(text, max_unbroken_word_width)}.max
          end
        end

        min_column_widths = min_word_widths.dup
        min_cells_width = min_column_widths.sum

        if min_cells_width > available_for_cells
          min_column_widths = Array.new(num_cols, 1)
          remaining = available_for_cells - num_cols
          if remaining > 0
            total_weight = min_word_widths.sum { |w| {0, w - 1}.max }
            growth = min_word_widths.map do |w|
              weight = {0, w - 1}.max
              total_weight > 0 ? (weight * remaining // total_weight) : 0
            end
            growth.each_with_index { |g, i| min_column_widths[i] += g }
            leftover = remaining - growth.sum
            i = 0
            while leftover > 0 && i < num_cols
              min_column_widths[i] += 1
              leftover -= 1
              i += 1
            end
          end
          min_cells_width = min_column_widths.sum
        end

        total_natural_width = natural_widths.sum + border_overhead

        if total_natural_width <= width
          col_widths = natural_widths.map_with_index { |w, idx| {w, min_column_widths[idx]}.max }
        else
          total_grow_potential = 0
          natural_widths.each_with_index do |w, idx|
            total_grow_potential += {0, w - min_column_widths[idx]}.max
          end
          extra_width = {0, available_for_cells - min_cells_width}.max
          col_widths = Array.new(num_cols, 0)
          natural_widths.each_with_index do |nat_w, idx|
            min_w = min_column_widths[idx]
            min_delta = {0, nat_w - min_w}.max
            grow = total_grow_potential > 0 ? (min_delta * extra_width // total_grow_potential) : 0
            col_widths[idx] = min_w + grow
          end

          remaining = available_for_cells - col_widths.sum
          while remaining > 0
            grew = false
            i = 0
            while i < num_cols && remaining > 0
              if col_widths[i] < natural_widths[i]
                col_widths[i] += 1
                remaining -= 1
                grew = true
              end
              i += 1
            end
            break unless grew
          end
        end

        top = "┌─" + col_widths.map { |w| "─" * w }.join("─┬─") + "─┐"
        lines << "  #{top}"

        render_table_cells(header, col_widths, true).each { |l| lines << l }

        sep = "├─" + col_widths.map { |w| "─" * w }.join("─┼─") + "─┤"
        lines << "  #{sep}"

        data_rows.each_with_index do |row, row_idx|
          render_table_cells(row, col_widths, false).each { |l| lines << l }
          lines << "  #{sep}" if row_idx < data_rows.size - 1
        end

        bottom = "└─" + col_widths.map { |w| "─" * w }.join("─┴─") + "─┘"
        lines << "  #{bottom}"

        lines
      end

      private def render_table_cells(cells : Array(String), col_widths : Array(Int32), bold : Bool) : Array(String)
        r = ANSI.reset
        cell_lines = cells.map_with_index do |cell, i|
          text = cell.strip
          w = col_widths[i]? || 1
          wrap_cell_text(text, w)
        end
        line_count = cell_lines.empty? ? 0 : cell_lines.max_of(&.size)

        result = [] of String
        line_count.times do |line_idx|
          parts = cell_lines.map_with_index do |lines_arr, col_idx|
            text = lines_arr[line_idx]? || ""
            w = col_widths[col_idx]? || 1
            padding = {0, w - visible_width(text)}.max
            bold ? "#{ANSI.bold}#{text}#{" " * padding}#{r}" : "#{text}#{" " * padding}"
          end
          result << "  │ #{parts.join(" │ ")} │"
        end
        result
      end

      private def parse_table_row(line : String) : Array(String)
        stripped = line.strip
        stripped = stripped.lchop('|') if stripped.starts_with?("|")
        stripped = stripped.rstrip.rstrip('|') if stripped.ends_with?("|")
        stripped.split('|').map(&.strip)
      end

      private def wrap_cell_text(text : String, max_width : Int32) : Array(String)
        wrap_line(text, {1, max_width}.max)
      end

      private def get_longest_word_width(text : String, max_width : Int32? = nil) : Int32
        longest = 0
        text.split(/\s+/).each do |word|
          next if word.empty?
          longest = {longest, visible_width(word)}.max
        end
        max_width ? {longest, max_width}.min : longest
      end

      # ------------------------------------------------------------------------
      # Horizontal rule detection
      # ------------------------------------------------------------------------

      private def horizontal_rule?(stripped : String) : Bool
        stripped.match(/\A(-{3,}|\*{3,}|_{3,})\z/) != nil
      end

      # ------------------------------------------------------------------------
      # Inline rendering
      # ------------------------------------------------------------------------

      private def render_inline(text : String) : String
        # During streaming, avoid flickering partial markdown markers.
        # If any pair-delimiter has an unmatched opener, render plain text.
        # Strip escaped delimiters before counting so \* doesn't count as *.
        clean = text.gsub(/\\[*_~`\[\]()\\]/, "")
        if clean.scan("**").size.odd? ||
           clean.scan("__").size.odd? ||
           clean.scan("~~").size.odd? ||
           clean.scan("`").size.odd?
          return text
        end

        result = IO::Memory.new
        i = 0
        chars = text.chars

        while i < chars.size
          c = chars[i]

          # --- escape sequences ---
          if c == '\\' && i + 1 < chars.size
            nxt = chars[i + 1]
            if nxt.in?('*', '_', '~', '`', '[', ']', '(', ')', '\\', '#', '+', '-', '.', '!', '>')
              result << nxt
              i += 2
              next
            end
          end

          # --- inline code ---
          if c == '`'
            close = chars.index('`', i + 1)
            if close
              code_text = chars[(i + 1)...close].join
              result << ANSI.color(@theme.colors.code, nil)
              result << code_text
              result << ANSI.reset
              i = close + 1
              next
            end
          end

          # --- bold **text** ---
          if c == '*' && i + 1 < chars.size && chars[i + 1] == '*'
            close = find_double(chars, '*', i + 2)
            if close
              inner = chars[(i + 2)...close].join
              result << ANSI.bold
              result << render_inline(inner)
              result << ANSI.reset
              i = close + 2
              next
            end
          end

          # --- bold __text__ ---
          if c == '_' && i + 1 < chars.size && chars[i + 1] == '_'
            close = find_double(chars, '_', i + 2)
            if close
              inner = chars[(i + 2)...close].join
              result << ANSI.bold
              result << render_inline(inner)
              result << ANSI.reset
              i = close + 2
              next
            end
          end

          # --- italic *text* (single asterisk, not intraword) ---
          if c == '*' && !(i + 1 < chars.size && chars[i + 1] == '*')
            prev_char = i > 0 ? chars[i - 1] : ' '
            if !prev_char.alphanumeric?
              close = find_single(chars, '*', i + 1)
              if close
                next_char = close + 1 < chars.size ? chars[close + 1] : ' '
                if !next_char.alphanumeric?
                  inner = chars[(i + 1)...close].join
                  result << ANSI.italic
                  result << render_inline(inner)
                  result << ANSI.reset
                  i = close + 1
                  next
                end
              end
            end
          end

          # --- italic _text_ (single underscore, not intraword) ---
          if c == '_' && !(i + 1 < chars.size && chars[i + 1] == '_')
            prev_char = i > 0 ? chars[i - 1] : ' '
            if !prev_char.alphanumeric?
              close = find_single(chars, '_', i + 1)
              if close
                next_char = close + 1 < chars.size ? chars[close + 1] : ' '
                if !next_char.alphanumeric?
                  inner = chars[(i + 1)...close].join
                  result << ANSI.italic
                  result << render_inline(inner)
                  result << ANSI.reset
                  i = close + 1
                  next
                end
              end
            end
          end

          # --- strikethrough ~~text~~ ---
          if c == '~' && i + 1 < chars.size && chars[i + 1] == '~'
            close = find_double(chars, '~', i + 2)
            if close
              inner = chars[(i + 2)...close].join
              result << ANSI.dim
              result << render_inline(inner)
              result << ANSI.reset
              i = close + 2
              next
            end
          end

          # --- link [text](url) ---
          if c == '['
            close = chars.index(']', i + 1)
            if close && close + 1 < chars.size && chars[close + 1] == '('
              url_end = chars.index(')', close + 2)
              if url_end
                link_text = chars[(i + 1)...close].join
                url = chars[(close + 2)...url_end].join
                result << ANSI.color(@theme.colors.link, nil)
                result << ANSI.underline
                result << render_inline(link_text)
                result << ANSI.reset
                # Show URL if different from link text
                if link_text != url && !url.starts_with?("mailto:")
                  result << ANSI.color(@theme.colors.dim, nil)
                  result << " (#{url})"
                  result << ANSI.reset
                end
                i = url_end + 1
                next
              end
            end
          end

          result << c
          i += 1
        end

        result.to_s
      end

      private def find_double(chars : Array(Char), target : Char, from : Int32) : Int32?
        i = from
        while i + 1 < chars.size
          return i if chars[i] == target && chars[i + 1] == target
          i += 1
        end
        # Check last position
        return i if i + 1 == chars.size && chars[i] == target
        nil
      end

      private def find_single(chars : Array(Char), target : Char, from : Int32) : Int32?
        chars.index(target, from)
      end

      # ------------------------------------------------------------------------
      # Infrastructure: visible width and ANSI-aware wrapping
      # ------------------------------------------------------------------------

      private def visible_width(str : String) : Int32
        CharWidth.visible_width(str)
      end

      private def wrap_line(styled_line : String, width : Int32) : Array(String)
        return [styled_line] if width <= 0
        vw = visible_width(styled_line)
        return [styled_line] if vw <= width

        tokens = tokenize_with_ansi(styled_line)

        result = [] of String
        current = ""
        current_w = 0
        last_color = ""

        tokens.each do |token|
          tw = visible_width(token)

          # Token itself too long — hard break
          if tw > width
            unless current.empty?
              result << current.rstrip
              current = ""
              current_w = 0
            end

            broken = break_long_token(token, width, last_color)
            broken[0...-1].each { |b| result << b }
            current = broken.last
            current_w = visible_width(current)
            last_color = extract_last_color(current)
            next
          end

          sep = current_w > 0 ? 1 : 0
          if current_w + sep + tw > width && current_w > 0
            result << current.rstrip
            current = last_color + token
            current_w = tw
          else
            current += ' ' if current_w > 0
            current += token
            current_w += sep + tw
          end

          last_color = extract_last_color(current)
        end

        s = current.rstrip
        result << s unless s.empty?
        result.empty? ? [""] : result
      end

      private def tokenize_with_ansi(str : String) : Array(String)
        tokens = [] of String
        current = ""
        in_escape = false
        seen_word = false

        str.each_char do |c|
          if in_escape
            current += c
            in_escape = false if c == 'm'
            next
          end
          if c == '\e'
            current += c
            in_escape = true
            next
          end
          if c == ' '
            if seen_word
              tokens << current unless current.empty?
              current = ""
            else
              current += c
            end
          else
            seen_word = true
            current += c
          end
        end

        tokens << current unless current.empty?
        tokens
      end

      private def break_long_token(token : String, width : Int32, color_prefix : String) : Array(String)
        result = [] of String
        current = ""
        current_w = 0
        in_escape = false

        token.each_char do |c|
          if in_escape
            current += c
            in_escape = false if c == 'm'
            next
          end
          if c == '\e'
            current += c
            in_escape = true
            next
          end

          cw = CharWidth.codepoint_width(c)
          if current_w + cw > width && current_w > 0
            result << current
            current = color_prefix
            current_w = 0
          end

          current += c
          current_w += cw
        end

        result << current unless current.empty?
        result.empty? ? [""] : result
      end

      private def extract_last_color(str : String) : String
        last_color = ""
        i = 0
        chars = str.chars
        while i < chars.size
          if chars[i] == '\e' && i + 1 < chars.size && chars[i + 1] == '['
            j = i + 2
            while j < chars.size && chars[j] != 'm'
              j += 1
            end
            if j < chars.size
              code = chars[i..j].join
              last_color = code
              i = j + 1
            else
              i += 1
            end
          else
            i += 1
          end
        end
        last_color
      end

      # ------------------------------------------------------------------------
      # Code syntax highlighting
      # ------------------------------------------------------------------------

      KEYWORDS = {
        "crystal" => %w(def end class module struct enum do if unless else elsif while until case when yield return next break begin rescue ensure raise require import include extend abstract property getter setter new spawn nil true false self super as typeof),
        "ruby"    => %w(def end class module do if unless else elsif while until case when yield return next break begin rescue ensure raise require include extend attr new nil true false self super),
        "python"  => %w(def class if elif else for while return import from as pass break continue with try except finally raise yield lambda None True False self global nonlocal assert del in is not and or),
        "js"      => %w(function const let var if else for while return import export from default class extends new typeof instanceof break continue try catch finally throw async await yield void delete this super switch case do nil undefined true false),
        "ts"      => %w(function const let var if else for while return import export from default class extends interface type enum new typeof instanceof break continue try catch finally throw async await yield void delete this super switch case do nil undefined true false public private protected readonly namespace),
        "go"      => %w(func var const type struct interface map chan if else for range return break continue case switch default go defer select package import nil true false),
        "rust"    => %w(fn let mut const static if else match for while loop return break continue struct enum trait impl pub use mod crate self Self super as where unsafe async await dyn ref type true false),
        "bash"    => %w(if then fi else elif case esac for in do done while until function return export local source echo printf unset set shift trap true false),
        "json"    => %w(true false null),
      }

      COMMENT_RE = {
        "crystal" => Regex.new("#.*$"),
        "ruby"    => Regex.new("#.*$"),
        "python"  => Regex.new("#.*$"),
        "bash"    => Regex.new("#.*$"),
        "rust"    => Regex.new("//.*$"),
        "go"      => Regex.new("//.*$"),
        "js"      => Regex.new("//.*$|/\\*.*\\*/"),
        "ts"      => Regex.new("//.*$|/\\*.*\\*/"),
      } of String => Regex

      def highlight_code(line : String, lang : String) : String
        return "#{ANSI.color(@theme.colors.code, nil)}  #{line}#{ANSI.reset}" if line.strip.empty?

        normalized = case lang.downcase
                     when "cr", "crystal"              then "crystal"
                     when "rb", "ruby"                 then "ruby"
                     when "py", "python"               then "python"
                     when "js", "javascript", "jsx"    then "js"
                     when "ts", "typescript", "tsx"    then "ts"
                     when "go", "golang"               then "go"
                     when "rs", "rust"                 then "rust"
                     when "sh", "bash", "shell", "zsh" then "bash"
                     when "json"                       then "json"
                     else                                   return "#{ANSI.color(@theme.colors.code, nil)}  #{line}#{ANSI.reset}"
                     end

        comment_re = COMMENT_RE[normalized]?
        kws = KEYWORDS[normalized]?
        code = @theme.colors.code

        # Highlight the line in ONE left-to-right pass. The previous code ran
        # four `gsub` passes over the accumulating result; once the first pass
        # inserted ANSI codes the later passes (notably the number pass) re-
        # matched the digits living inside those escapes — the `38`/`5` in
        # `\e[38;5;75m` — and wrapped them again, splitting each escape into
        # broken CSI fragments that printed as stray `38;5;75m` text. By
        # classifying each span of the original line exactly once we never
        # re-scan inserted escapes.
        string_src = /"([^"\\]|\\.)*"|'([^'\\]|\\.)*'/.source
        number_src = /\b\d+\.?\d*\b/.source

        alts = [] of String
        alts << "(?<comment>#{comment_re.source})" if comment_re
        alts << "(?<str>#{string_src})"
        alts << "(?<num>#{number_src})"
        if kws && !kws.empty?
          alts << "(?<kw>\\b(?:#{kws.map { |kw| Regex.escape(kw) }.join("|")})\\b)"
        end

        buf = IO::Memory.new
        pos = 0
        line.scan(Regex.new(alts.join("|"))) do |m|
          start_pos = m.begin(0)
          buf << line[pos...start_pos] if pos < start_pos
          pos = m.end(0)
          token = m[0]
          if comment_re && m["comment"]?
            buf << ANSI.color(@theme.colors.dim, nil) << ANSI.italic << token
          elsif m["str"]?
            buf << ANSI.color(@theme.colors.success, nil) << token
          elsif m["num"]?
            buf << ANSI.color(@theme.colors.warning, nil) << token
          else
            buf << ANSI.color(@theme.colors.accent, nil) << ANSI.bold << token
          end
          buf << ANSI.reset << ANSI.color(code, nil)
        end
        buf << line[pos..] if pos < line.size
        result = buf.to_s

        "#{ANSI.color(code, nil)}  #{result}#{ANSI.reset}"
      end

      # ------------------------------------------------------------------------
      # Internal render state
      # ------------------------------------------------------------------------

      private class RenderState
        property? in_code_block : Bool = false
        property code_lang : String = ""
        property? in_table : Bool = false
        property table_rows : Array(String) = [] of String
        property last_block : Symbol = :none
      end
    end
  end
end
