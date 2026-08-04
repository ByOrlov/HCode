module Hcode
  module TUI
    # Abstract terminal interface that zones and the orchestrator use for all
    # screen output. Two implementations exist: `TerminalMock` (array-backed,
    # for tests) and `AnsiTerminalPort` (writes ANSI sequences to a real IO).
    #
    # Two distinct "advance to next row" operations:
    # - `newline` (`\r\n`) — used by LogZone; triggers the terminal's natural
    #   scroll when issued at the bottom row.
    # - `cursor_down` + `carriage_return` — used by ActiveZone; never scrolls.
    module TerminalPort
      abstract def cursor_down(n : Int32 = 1) : Nil
      abstract def cursor_up(n : Int32 = 1) : Nil
      abstract def cursor_home : Nil
      abstract def cursor_to_column(col : Int32) : Nil
      abstract def hide_cursor : Nil
      abstract def show_cursor : Nil
      abstract def carriage_return : Nil
      abstract def clear_line : Nil
      abstract def clear_below : Nil
      abstract def write(str : String) : Nil
      abstract def newline : Nil
      abstract def begin_frame : Nil
      abstract def end_frame : Nil
      abstract def rows : Int32
      abstract def cols : Int32
    end
  end
end
