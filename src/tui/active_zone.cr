module Hcode
  module TUI
    # Stateless renderer for the repainted region at the bottom of the screen.
    #
    # Unlike the previous implementation, this zone does NOT track blank rows,
    # height history, or shift state. It simply paints the active content at the
    # current cursor position and clears any rows that are no longer used.
    class ActiveZone
      # Render `active_lines` starting at the current cursor row.
      #
      # If the zone is taller than `available_rows`, only the bottom portion is
      # drawn (tail-clipping) so the editor/footer stay visible.
      #
      # `prev_visible` is how many rows the zone occupied on the previous frame.
      # If it was larger, the leftover rows are cleared with `\e[J`.
      #
      # Returns the number of visible rows actually drawn.
      def render(port : TerminalPort, active_lines : Array(String), available_rows : Int32, prev_visible : Int32) : Int32
        visible = Math.min(active_lines.size, available_rows)
        skip = active_lines.size - visible

        visible.times do |vi|
          port.cursor_down(1) if vi > 0
          port.carriage_return
          port.clear_line
          port.write(active_lines.unsafe_fetch(skip + vi))
        end

        if prev_visible > visible
          port.cursor_down(1) if visible > 0
          port.carriage_return
          port.clear_below
        end

        visible
      end
    end
  end
end
