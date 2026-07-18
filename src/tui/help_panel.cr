module Hcode
  module TUI
    # Modal `/help` overlay — mirrors Moonshot kimi-code's `HelpPanelComponent`.
    #
    # Replaces the editor while visible: the host renders `render(cols)` in the
    # editor slot and routes all keys to `handle_input`. Dismissed via Esc /
    # Enter / q. Scrollable with ↑/↓ (1 row) and PageUp/PageDown (10 rows)
    # when content overflows the viewport.
    #
    # The renderer invariant ("one `Array(String)` element == one terminal
    # row") is upheld by splitting content into individual lines here, never
    # embedding `\n` inside an element. The earlier `/help` bug — pushing a
    # multi-line `system` message that broke `diff_render`'s row math — is
    # avoided by design.
    class HelpPanel
      struct Shortcut
        property keys : String
        property description : String

        def initialize(@keys : String, @description : String)
        end
      end

      DEFAULT_SHORTCUTS = [
        Shortcut.new("Enter", "Submit"),
        Shortcut.new("Shift+Enter", "Insert newline"),
        Shortcut.new("Ctrl+C", "Interrupt stream / clear input"),
        Shortcut.new("Ctrl+D", "Exit (on empty input)"),
        Shortcut.new("Ctrl+S", "Steer — queue a follow-up during streaming"),
        Shortcut.new("Ctrl+G", "Edit in external editor ($VISUAL / $EDITOR)"),
        Shortcut.new("Ctrl+E", "Expand pasted block"),
        Shortcut.new("Esc", "Close dialogs / interrupt streaming"),
        Shortcut.new("Up/Down", "Browse input history"),
      ]

      property? visible : Bool = false
      property max_visible : Int32 = 24
      # Callback fired when the user dismisses the panel.
      property on_close : (-> Nil)?

      @theme : Theme
      @commands : Array(CommandInfo)
      @shortcuts : Array(Shortcut)
      @scroll : Int32 = 0
      # Lines between the top/bottom borders — recomputed lazily inside
      # `render` so the panel reacts to a terminal resize without `show`.
      @content : Array(String) = [] of String

      def initialize(@theme : Theme,
                     commands : Array(CommandInfo)? = nil,
                     shortcuts : Array(Shortcut)? = nil)
        @commands = commands || CommandRegistry::COMMANDS.to_a
        @shortcuts = shortcuts || DEFAULT_SHORTCUTS
      end

      def show : Nil
        @scroll = 0
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
        when .up?
          @scroll = {@scroll - 1, 0}.max
          true
        when .down?
          @scroll += 1 # render clamps
          true
        when .page_up?
          @scroll = {@scroll - 10, 0}.max
          true
        when .page_down?
          @scroll += 10
          true
        else
          false
        end
      end

      private def close : Nil
        @visible = false
        @on_close.try(&.call)
      end

      # Render the panel as a list of terminal lines, bounded to `cols`.
      # Top border + scrollable content + (optional) scroll indicator + bottom
      # border. Each returned element is exactly one terminal row.
      def render(cols : Int32) : Array(String)
        lines = [] of String

        accent = ANSI.color(@theme.colors.accent, nil)
        primary = ANSI.color(@theme.colors.primary, nil)
        muted = ANSI.color(@theme.colors.muted, nil)
        dim = ANSI.color(@theme.colors.dim, nil)
        warn = ANSI.color(@theme.colors.warning, nil)
        r = ANSI.reset

        rule = "#{accent}#{CharWidth.truncate_to_width("─" * cols, cols)}#{r}"

        lines << rule
        lines << truncate("#{primary}#{ANSI.bold} help #{r}#{muted}· Esc / Enter / q to cancel · ↑↓ scroll#{r}", cols)
        lines << truncate("  #{dim}Sure, HCode is ready to help! Just send a message to get started.#{r}", cols)
        lines << ""

        lines << truncate("  #{ANSI.bold}Keyboard shortcuts#{r}", cols)
        kbd_w = pad_width(@shortcuts.map(&.keys))
        @shortcuts.each do |s|
          lines << truncate("    #{warn}#{s.keys.ljust(kbd_w)}#{r}  #{dim}#{s.description}#{r}", cols)
        end
        lines << ""

        lines << truncate("  #{ANSI.bold}Slash commands#{r}", cols)
        sorted = @commands.to_a.sort { |a, b| a.name <=> b.name }
        cmd_w = pad_width(sorted.map(&.name))
        sorted.each do |cmd|
          lines << truncate("    #{primary}#{cmd.name.ljust(cmd_w)}#{r}  #{dim}#{cmd.description}#{r}", cols)
        end

        @content = lines
        apply_scroll_window(lines, cols, rule)
      end

      private def apply_scroll_window(lines : Array(String), cols : Int32, rule : String) : Array(String)
        # Slice [1, size-1) keeps both borders pinned when windowing.
        content = lines[1...lines.size - 1]? || [] of String
        max = {@max_visible, 5}.max
        if content.size <= max
          @scroll = 0
          return lines.map { |l| truncate(l, cols) }
        end

        max_offset = {content.size - max, 0}.max
        @scroll = {@scroll, max_offset}.min
        @scroll = {@scroll, 0}.max

        slice = content[@scroll, max]? || [] of String
        info = "#{ANSI.color(@theme.colors.muted, nil)} showing #{@scroll + 1}-#{@scroll + slice.size} of #{content.size}#{ANSI.reset}"
        [lines[0]] + slice.map { |l| truncate(l, cols) } + [truncate(info, cols), truncate(rule, cols)]
      end

      private def truncate(line : String, cols : Int32) : String
        CharWidth.truncate_to_width(line, cols)
      end

      private def pad_width(values : Array(String)) : Int32
        w = 8
        values.each { |v| w = {w, v.size}.max }
        w
      end
    end
  end
end
