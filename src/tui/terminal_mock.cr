module Hcode
  module TUI
    # Screen-model `TerminalPort` for tests. Models the behaviour of a real
    # terminal screen buffer: a fixed grid of `@rows` × `@cols`, a physical
    # cursor clamped to the grid, natural scroll when `newline` is issued at
    # the bottom row (the top line is pushed into `@scrollback`), and in-place
    # row writes via `write` + `clear_line`.
    #
    # `screen` exposes the visible grid; `scrollback` exposes lines that have
    # scrolled off the top; `visible_rows` is the two concatenated — the full
    # logical transcript of what has been "drawn", which is what zone tests
    # assert against.
    class TerminalMock
      include TerminalPort

      @screen : Array(String)
      @scrollback : Array(String) = [] of String
      @cursor_row : Int32 = 0
      @cursor_col : Int32 = 0
      @max_touched : Int32 = -1

      getter scrollback : Array(String)
      getter cursor_row : Int32
      getter cursor_col : Int32

      def initialize(@rows : Int32 = 24, @cols : Int32 = 80)
        @screen = Array(String).new(@rows) { "" }
      end

      private def touch : Nil
        @max_touched = @cursor_row if @cursor_row > @max_touched
      end

      def cursor_down(n : Int32 = 1) : Nil
        return if n <= 0
        @cursor_row = {@cursor_row + n, @rows - 1}.min
      end

      def cursor_up(n : Int32 = 1) : Nil
        return if n <= 0
        @cursor_row = {@cursor_row - n, 0}.max
      end

      def cursor_home : Nil
        @cursor_row = 0
        @cursor_col = 0
      end

      def cursor_to_column(col : Int32) : Nil
        @cursor_col = {col, 0}.max
      end

      def hide_cursor : Nil
      end

      def show_cursor : Nil
      end

      def carriage_return : Nil
        @cursor_col = 0
      end

      def clear_line : Nil
        @screen[@cursor_row] = ""
        touch
      end

      def clear_below : Nil
        # ED (\e[J) erases from the cursor rightward on the current row, then
        # all rows below in full. Content left of the cursor survives.
        cur = @screen[@cursor_row]
        @screen[@cursor_row] = @cursor_col >= cur.size ? cur : cur[0...@cursor_col]
        (@cursor_row + 1...@rows).each { |i| @screen[i] = "" }
      end

      def write(str : String) : Nil
        # Mirror a real terminal: write at the cursor column, preserving any
        # existing content to the left. A prior clear_line (\e[2K) empties the
        # row so this produces a clean write; without it, stale tail content
        # beyond the written text survives — exactly like a real terminal.
        cur = @screen[@cursor_row]
        prefix = @cursor_col < cur.size ? cur[0...@cursor_col] : cur
        @screen[@cursor_row] = prefix + str
        @cursor_col = {@cursor_col + str.size, @cols - 1}.min
        touch
      end

      def newline : Nil
        if @cursor_row < @rows - 1
          @cursor_row += 1
          touch
        else
          # Bottom row: scroll up. Top line leaves the visible grid.
          @scrollback << @screen[0]
          (@rows - 1).times { |i| @screen[i] = @screen[i + 1] }
          @screen[@rows - 1] = ""
          @cursor_row = @rows - 1
          @max_touched = @rows - 1
        end
        @cursor_col = 0
      end

      def begin_frame : Nil
      end

      def end_frame : Nil
      end

      def rows : Int32
        @rows
      end

      def cols : Int32
        @cols
      end

      # The visible grid (rows top→bottom).
      def screen : Array(String)
        @screen.dup
      end

      # Scrollback + visible grid. Trailing blank rows are stripped so that
      # cleared rows below the active zone do not appear in the logical
      # transcript. This mirrors the new blank-free rendering model.
      def visible_rows : Array(String)
        return @scrollback.dup if @max_touched < 0
        last = {@max_touched, @rows - 1}.min
        # Strip rows that were cleared below the active zone.
        while last >= 0 && @screen[last].empty?
          last -= 1
        end
        return @scrollback.dup if last < 0
        @scrollback + @screen[0..last]
      end

      # Alias retained for tests written against the old array-backed mock.
      def output : Array(String)
        visible_rows
      end
    end
  end
end
