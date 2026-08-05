module Hcode
  module TUI
    # Stateless renderer for the repainted region at the bottom of the screen.
    #
    # Paints the active content at the current cursor position. Does NOT clear
    # rows below the zone — that is the caller's responsibility because only the
    # caller knows the absolute screen geometry (needed to avoid wiping the last
    # active row when the zone reaches the bottom of the screen).
    class ActiveZone
      # Render `active_lines` starting at the current cursor row.
      #
      # If the zone is taller than `available_rows`, only the bottom portion is
      # drawn (tail-clipping) so the editor/footer stay visible.
      #
      # `prev_visible` is accepted for API compatibility but no longer used —
      # clearing stale rows below the zone is handled by `incremental_render`.
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

        visible
      end
    end
  end
end
