module Hcode
  module TUI
    # `TerminalPort` implementation that writes ANSI escape sequences to a real
    # IO (typically `IO::Memory` built per frame by the orchestrator, then
    # printed to STDOUT). Geometry (`rows`, `cols`) is delegated to the wrapped
    # `Terminal`.
    class AnsiTerminalPort
      include TerminalPort

      def initialize(@io : IO, @terminal : Terminal)
      end

      def cursor_down(n : Int32 = 1) : Nil
        @io << "\e[#{n}B" if n > 0
      end

      def cursor_up(n : Int32 = 1) : Nil
        @io << "\e[#{n}A" if n > 0
      end

      def cursor_home : Nil
        @io << "\e[H"
      end

      def cursor_to_column(col : Int32) : Nil
        @io << "\e[#{col}G"
      end

      def hide_cursor : Nil
        @io << ANSI.hide_cursor
      end

      def show_cursor : Nil
        @io << ANSI.show_cursor
      end

      def carriage_return : Nil
        @io << "\r"
      end

      def clear_line : Nil
        @io << "\e[2K"
      end

      def clear_below : Nil
        @io << "\e[J"
      end

      def write(str : String) : Nil
        @io << str
      end

      def newline : Nil
        @io << "\r\n"
      end

      def begin_frame : Nil
        @io << "\e[?2026h"
      end

      def end_frame : Nil
        @io << "\e[?2026l"
      end

      def rows : Int32
        @terminal.rows
      end

      def cols : Int32
        @terminal.cols
      end
    end
  end
end
