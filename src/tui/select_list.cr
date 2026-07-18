module Kimi
  module TUI
    class SelectList
      property items : Array(String)
      property selected : Int32 = 0
      property? visible : Bool = false
      property title : String = ""
      # Maximum number of rows rendered at once. The list scrolls when there
      # are more items, keeping the selection always visible.
      property max_visible : Int32 = 8
      @theme : Theme
      @scroll_offset : Int32 = 0

      def initialize(@items : Array(String) = [] of String, @theme : Theme = Theme.dark)
      end

      def show(title : String, items : Array(String)) : Nil
        @title = title
        @items = items
        @selected = 0
        @scroll_offset = 0
        @visible = true
      end

      def hide : Nil
        @visible = false
      end

      def current : String?
        @items[@selected]?
      end

      def handle_input(key : KeyEvent) : Bool
        return false unless @visible

        case key.key
        when .up?
          @selected = (@selected - 1 + @items.size) % @items.size if @items.size > 0
          true
        when .down?
          @selected = (@selected + 1) % @items.size if @items.size > 0
          true
        when .enter?
          true
        when .escape?
          hide
          true
        else
          false
        end
      end

      # Compute the visible window [start, count) and lazily adjust the
      # scroll offset so the selected row is always on screen.
      def visible_window : {Int32, Int32}
        return {0, 0} if @items.empty?
        mv = {@max_visible, @items.size}.min
        if @selected < @scroll_offset
          @scroll_offset = @selected
        elsif @selected >= @scroll_offset + mv
          @scroll_offset = {@selected - mv + 1, 0}.max
        end
        max_offset = {@items.size - mv, 0}.max
        @scroll_offset = {@scroll_offset, max_offset}.min
        {@scroll_offset, mv}
      end

      # True when there are rows above the current viewport.
      def scrolled_up? : Bool
        _, _ = visible_window
        @scroll_offset > 0
      end

      # True when there are rows below the current viewport.
      def scrolled_down? : Bool
        start, count = visible_window
        start + count < @items.size
      end

      def render(io : IO, x : Int32, y : Int32, width : Int32) : Nil
        return unless @visible
        return if @items.empty?

        io << ANSI.color(@theme.colors.accent, nil)
        io << ANSI.bold
        io << ANSI.cursor_to(y, x)
        io << @title
        io << ANSI.reset
        io << ANSI.clear_line

        start, count = visible_window
        count.times do |rel|
          i = start + rel
          item = @items[i]
          io << ANSI.cursor_to(y + 1 + rel, x)
          if i == @selected
            io << ANSI.color(@theme.colors.accent, nil)
            io << ANSI.bold
            io << "▶ #{item}"
            io << ANSI.reset
          else
            io << ANSI.color(@theme.colors.muted, nil)
            io << "  #{item}"
            io << ANSI.reset
          end
          io << ANSI.clear_line
        end
      end

      # Rendered body height (title + visible rows + hint), used by the app
      # layout to reserve vertical space.
      def height : Int32
        return 0 unless @visible
        return 0 if @items.empty?
        _, count = visible_window
        count + 2
      end
    end
  end
end
