module Hcode
  module TUI
    # Modal `/usage` overlay. Replaces the editor while visible, mirroring the
    # `HelpPanel` pattern: the host renders `render(cols)` in the editor slot
    # and routes keys to `handle_input`. Dismissed via Esc / Enter / q.
    #
    # Shows the live session metrics: provider, model, token usage against the
    # context window, message count, and queue depth.
    class UsagePanel
      property? visible : Bool = false
      property on_close : (-> Nil)?

      def initialize(@theme : Theme)
      end

      def show : Nil
        @visible = true
      end

      def hide : Nil
        @visible = false
      end

      # Returns true when the key was consumed (caller should skip further
      # dispatch). Esc / Enter / q close the panel.
      def handle_input(key : KeyEvent) : Bool
        return false unless @visible

        case key.key
        when .escape?, .enter?
          close
          true
        when .char?
          c = key.char
          if c && (c == 'q' || c == 'Q')
            close
            true
          else
            false
          end
        else
          false
        end
      end

      private def close : Nil
        @visible = false
        @on_close.try(&.call)
      end

      # Render the usage panel as a list of terminal lines, bounded to `cols`.
      # The snapshot is taken at render time so the numbers are always live.
      def render(cols : Int32, provider : String, model : String,
                 context_tokens : Int32, max_context_tokens : Int32,
                 context_percent : Float64, messages_count : Int32,
                 queue_size : Int32) : Array(String)
        lines = [] of String

        accent = ANSI.color(@theme.colors.accent, nil)
        primary = ANSI.color(@theme.colors.primary, nil)
        muted = ANSI.color(@theme.colors.muted, nil)
        dim = ANSI.color(@theme.colors.dim, nil)
        warn = ANSI.color(@theme.colors.warning, nil)
        error = ANSI.color(@theme.colors.error, nil)
        success = ANSI.color(@theme.colors.success, nil)
        r = ANSI.reset

        rule = truncate("#{accent}#{CharWidth.truncate_to_width("─" * cols, cols)}#{r}", cols)

        lines << rule
        lines << truncate("#{primary}#{ANSI.bold} usage #{r}#{muted}· Esc / Enter / q to close#{r}", cols)
        lines << ""

        # Context bar visualization.
        pct = context_percent.round(1)
        bar_color = pct >= 90 ? error : pct >= 75 ? warn : success
        bar_width = {cols - 16, 10}.max
        filled = (bar_width * (pct / 100.0)).round.to_i.clamp(0, bar_width)
        empty = bar_width - filled
        bar_line = String.build do |s|
          s << "  #{dim}Context#{r} "
          s << "#{bar_color}#{filled.times.map { '█' }.join}#{r}"
          s << "#{dim}#{empty.times.map { '░' }.join}#{r}"
          s << " #{bar_color}#{pct}%#{r}"
        end
        lines << truncate(bar_line, cols)

        if max_context_tokens > 0
          lines << truncate("  #{dim}Tokens:#{r} #{context_tokens} / #{max_context_tokens}#{r}", cols)
        end
        lines << ""

        rows = [
          {"Provider", provider},
          {"Model", model},
          {"Messages", messages_count.to_s},
          {"Queue", queue_size.to_s},
        ]
        label_w = 10
        rows.each do |label, value|
          lines << truncate("  #{dim}#{label.ljust(label_w)}#{r} #{primary}#{value}#{r}", cols)
        end

        lines << ""
        lines << truncate(rule, cols)
        lines
      end

      private def truncate(line : String, cols : Int32) : String
        CharWidth.truncate_to_width(line, cols)
      end
    end
  end
end
