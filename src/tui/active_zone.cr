module Hcode
  module TUI
    # The repainted zone: spinner/status, live thinking, streaming text, the
    # editor, dialogs — everything below the immutable log. Its state is held
    # here (current lines) and its height each frame is logged into a bounded
    # buffer (`#height_log`).
    #
    # `#render` redraws the whole zone in place every frame through a
    # `TerminalPort`:
    # - draws the first `available_rows` lines (with `A1` at the top); if the
    #   zone is virtually taller than the viewport, the tail is clipped;
    # - when the zone shrank, blank rows are drawn BELOW the content (trailing
    #   blanks) so stale content is erased (was 10 → became 8: 2 blank rows);
    # - `#trailing_blanks` tracks how many blank rows pad the zone; the
    #   orchestrator consumes them via `#consume_blank` when new log lines are
    #   pushed (shift), keeping the total screen height stable until the blanks
    #   are exhausted.
    #
    # See `docs/TUI_ZONES.md`.
    class ActiveZone
      HEIGHT_LOG_CAP = 16

      @lines : Array(String) = [] of String
      @height_log : Array(Int32) = [] of Int32
      @trailing_blanks : Int32 = 0
      @planned : Bool = false
      @last_painted : Int32 = 0

      getter lines : Array(String)
      getter height_log : Array(Int32)
      getter trailing_blanks : Int32
      getter last_painted : Int32

      # Virtual height of the zone (number of lines stored), independent of the
      # viewport.
      def height : Int32
        @lines.size
      end

      # The height actually drawn on the previous frame (last entry in the
      # height log). Used as the threshold for blank-line padding on shrink.
      def prev_height : Int32
        @height_log.last? || 0
      end

      # Total blank rows padding the zone (always trailing, below the content).
      def blanks_count : Int32
        @trailing_blanks
      end

      # The blank rows available for shift consumption.
      def available_blanks : Int32
        @trailing_blanks
      end

      # Whether there are blank rows that can be consumed by a log push
      # (shift). When true, the orchestrator calls `#consume_blank` before
      # flushing each new log line so the active zone shifts into the blank
      # space instead of growing the screen.
      def shift_available? : Bool
        @trailing_blanks > 0
      end

      # Consume one blank row (called by the orchestrator per shifted log
      # line). Decrements trailing blanks; never goes below 0.
      def consume_blank : Nil
        @trailing_blanks -= 1 if @trailing_blanks > 0
      end

      # Remember the zone's lines for this frame.
      def set(@lines : Array(String)) : Nil
        @planned = false
      end

      # Pre-compute blank rows for this frame without drawing. Called
      # automatically by `#render` if not already called, but the orchestrator
      # calls it explicitly so `#blanks_count` is available before
      # `viewport_top` is computed.
      def plan(available_rows : Int32) : Nil
        @planned = true
        available = available_rows < 0 ? 0 : available_rows
        prev_visible = prev_height
        visible = {@lines.size, available}.min

        if visible < prev_visible
          pad = prev_visible - visible
          max_pad = available > visible ? available - visible : 0
          @trailing_blanks = {pad, max_pad}.min
        elsif visible > prev_visible
          consumed = {visible - prev_visible, @trailing_blanks}.min
          @trailing_blanks -= consumed
        end
      end

      # Redraw the zone into `port` from the current cursor position (assumed
      # to be the zone's top row, column 0).
      #
      # `available_rows` is how many terminal rows fit below the cursor; the
      # zone is clamped to it. Blank rows are drawn BELOW the content (trailing
      # blanks) to erase stale content after a shrink. The visible height is
      # pushed to `#height_log`.
      def render(port : TerminalPort, available_rows : Int32) : Nil
        plan(available_rows) unless @planned

        available = available_rows < 0 ? 0 : available_rows
        visible = {@lines.size, available}.min

        visible.times do |vi|
          port.cursor_down(1) if vi > 0
          port.carriage_return
          port.clear_line
          port.write(@lines.unsafe_fetch(vi))
        end

        @trailing_blanks.times do
          port.cursor_down(1)
          port.carriage_return
          port.clear_line
        end

        @last_painted = visible + @trailing_blanks

        record_height(visible)
      end

      # Seed the height baseline after a full repaint (which paints the zone
      # but bypasses `#render`). Without this the first incremental frame
      # would see `prev_height == 0` and miss a subsequent shrink.
      def seed_baseline(available_rows : Int32) : Nil
        available = available_rows < 0 ? 0 : available_rows
        visible = {@lines.size, available}.min
        @height_log = [visible]
        @trailing_blanks = 0
        @last_painted = visible
        @planned = false
      end

      # Clear stored state, the height log, and blanks (transcript rebuild).
      def reset : Nil
        @lines = [] of String
        @height_log = [] of Int32
        @trailing_blanks = 0
        @last_painted = 0
        @planned = false
      end

      private def record_height(visible : Int32) : Nil
        @height_log << visible
        @height_log.shift if @height_log.size > HEIGHT_LOG_CAP
      end
    end
  end
end
