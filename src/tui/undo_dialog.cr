module Hcode
  module TUI
    # Port of the TS `UndoSelectorComponent`
    # (`apps/kimi-code/src/tui/components/dialogs/undo-selector.ts`).
    #
    # Lists user-turn candidates that can be rolled back; selecting one calls
    # `Agent#undo(count)` with that turn's count, cancelling restores the
    # prior state. Built on SelectList (same as provider/model selectors):
    # ↑↓ navigate, Enter select, Esc cancel. Selecting below the cursor marks
    # the "in undo range" — those turns are the ones that will be dropped.
    class UndoDialog
      MAX_VISIBLE               = 5
      PREFERRED_SELECTED_OFFSET = 2

      struct Choice
        getter id : String
        getter count : Int32
        getter input : String
        getter label : String

        def initialize(@id : String, @count : Int32, @input : String, @label : String)
        end
      end

      getter? visible : Bool = false
      getter choices : Array(Choice) = [] of Choice
      getter selected : Int32 = 0
      @theme : Theme
      @on_select : (Choice -> Nil)?
      @on_cancel : (-> Nil)?

      def initialize(@theme : Theme = Theme.dark)
      end

      def show(choices : Array(Choice),
               on_select : Choice -> Nil,
               on_cancel : (-> Nil)? = nil) : Nil
        @choices = choices
        @on_select = on_select
        @on_cancel = on_cancel
        # Default to the last choice (mirrors TS `initialIndex`).
        @selected = {0, choices.size - 1}.max
        @visible = true
      end

      def hide : Nil
        @visible = false
      end

      def handle_input(key : KeyEvent) : Nil
        case key.key
        when .up?
          move(-1)
        when .down?
          move(1)
        when .enter?
          if choice = @choices[@selected]?
            c = choice
            hide
            @on_select.try(&.call(c))
          end
        when .escape?
          hide
          @on_cancel.try(&.call)
        end
      end

      private def move(delta : Int32) : Nil
        return if @choices.empty?
        @selected = (@selected + delta + @choices.size) % @choices.size
      end

      def render(width : Int32) : Array(String)
        return [] of String unless @visible
        accent = @theme.colors.primary
        dim = @theme.colors.dim

        lines = [] of String
        lines << "#{ANSI.color(accent, nil)}#{"─" * width}#{ANSI.reset}"
        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold} Select messages to undo#{ANSI.reset}"
        lines << "#{ANSI.color(dim, nil)} ↑↓ navigate · Enter select · Esc cancel#{ANSI.reset}"
        lines << ""

        if @choices.empty?
          lines << "#{ANSI.color(dim, nil)}   No messages#{ANSI.reset}"
        else
          visible_count = Math.min(MAX_VISIBLE, @choices.size)
          max_start = {0, @choices.size - visible_count}.max
          start = Math.min(Math.max(0, @selected - PREFERRED_SELECTED_OFFSET), max_start)
          ends = start + visible_count
          (start...ends).each do |i|
            choice = @choices[i]?
            next unless choice
            lines << render_choice(choice, i == @selected, i > @selected, width)
          end
        end

        lines << ""
        lines << "#{ANSI.color(accent, nil)}#{"─" * width}#{ANSI.reset}"
        lines
      end

      private def render_choice(choice : Choice, is_selected : Bool,
                                in_undo_range : Bool, width : Int32) : String
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        text = @theme.colors.text

        pointer = is_selected ? "▶" : " "
        prefix = "  #{pointer} "

        # Truncate the label to fit the remaining width.
        budget = {8, width - prefix.size}.max
        label = choice.label.size > budget ? "#{choice.label[0...(budget - 1)]}…" : choice.label

        prefix_color = is_selected ? accent : dim
        token = is_selected ? accent : (in_undo_range ? dim : text)
        bold = is_selected ? ANSI.bold : ""
        "#{ANSI.color(prefix_color, nil)}#{prefix}#{ANSI.color(token, nil)}#{bold}#{label}#{ANSI.reset}"
      end
    end
  end
end
