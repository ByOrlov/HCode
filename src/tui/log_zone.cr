module H2code
  module TUI
    # Append-only emission sink for immutable history lines (user/assistant
    # messages, tool results, thinking blocks). Lines flushed here are written
    # to the terminal once and never rewritten — they scroll into the
    # scrollback naturally as the active zone below them grows.
    #
    # The zone stores NO content state (the history is the source of truth in
    # `App#@messages`); it tracks only an emission cursor — how many log lines
    # have already been handed to the terminal. Viewport/scroll mechanics live
    # in the orchestrator (`App`); `LogZone` only emits the new lines beyond
    # the cursor. See `docs/TUI_ZONES.md`.
    # Maximum number of new log lines LogZone will hand to the terminal in a
    # single frame. Capped to one viewport so the incremental scroll path never
    # has to advance the viewport by more than a screen at once — a tool that
    # dumps hundreds of lines (or a plan block that migrates wholesale from the
    # active zone) is split across consecutive frames instead of corrupting the
    # screen in one shot. See `docs/TUI_ZONES.md`.
    MAX_FLUSH_PER_FRAME = 4096

    class LogZone
      @flushed : Int32 = 0
      @shrank : Bool = false
      # True when lines were held back this frame because the pending block
      # exceeded the per-frame chunk. The render loop keeps re-rendering until
      # the whole block is drained.
      @pending : Bool = false

      getter flushed : Int32

      # True if the log has shrunk below the emission cursor (e.g. welcome box
      # hidden, transcript cleared/compacted). When `total` is given it is
      # compared against the current cursor; otherwise the stored flag is read.
      def shrank?(total : Int32? = nil) : Bool
        if t = total
          return true if t < @flushed
        end
        @shrank
      end

      # Whether more lines are queued and need another render frame to flush.
      def pending? : Bool
        @pending
      end

      # How many of `total` log lines may be flushed this frame. Advances the
      # revealed window toward `total` by at most `chunk` lines, where `chunk`
      # is clamped to the viewport height — guaranteeing the renderer never sees
      # a log jump larger than the screen. Sets `pending?` when lines remain.
      # Must be called with the same `total` the renderer is about to draw.
      def reveal_limit(total : Int32, chunk : Int32) : Int32
        c = {chunk, 1}.max
        target = {total, @flushed + c}.min
        @pending = target < total
        target
      end

      # Emit `log_lines[flushed..]` through `port`. Each new line clears the
      # current row, writes the content, then advances with `cursor_down`
      # (never `newline`) — advancing without scroll is essential: the
      # orchestrator's scroll step already emitted the `\r\n`s that push the
      # log top into scrollback, so a per-line `newline` here would scroll
      # again and double-count. The orchestrator pre-positions the cursor at
      # the first unflushed row. Returns the number of newly emitted lines
      # and advances the cursor. If the history shrank below the cursor
      # (compaction / clear), sets `shrank?` and emits nothing — the
      # orchestrator then does a full repaint.
      def flush(port : TerminalPort, log_lines : Array(String)) : Int32
        if log_lines.size < @flushed
          @shrank = true
          return 0
        end

        emitted = 0
        while @flushed < log_lines.size
          port.carriage_return
          port.clear_line
          port.write(log_lines[@flushed])
          # Cancel pending-wrap before cursor_down — a full-width line leaves
          # the terminal in a state where cursor_down can double-wrap.
          port.carriage_return
          port.cursor_down(1)
          @flushed &+= 1
          emitted &+= 1
        end
        emitted
      end

      # Reset the emission cursor to 0 and clear `shrank?`. Called after a
      # full repaint or a transcript rebuild (`load_transcript_from`). Does NOT
      # clear `pending?` — that flag is owned by `reveal_limit`, which runs
      # every frame before the render decision, so it always reflects whether
      # more lines remain queued regardless of which render path executed.
      def reset : Nil
        @flushed = 0
        @shrank = false
      end

      # Align the cursor after the orchestrator performed a full repaint that
      # already wrote every line to the terminal.
      def mark_flushed(count : Int32) : Nil
        @flushed = count
        @shrank = false
      end
    end
  end
end
