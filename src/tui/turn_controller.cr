module Hcode
  module TUI
    module TurnController
      private def submit_message(text : String) : Nil
        text = text.strip
        return if text.empty?

        # Gate mirrors the TS three-flag rule: defer the message (queue it)
        # when a turn is running, compaction is in flight, or a meta-command
        # asked us to defer. Idle + nothing-deferred → send immediately.
        if @agent_busy || @is_compacting || @defer_user_messages
          enqueue_message(text)
          return
        end

        start_turn(text)
      end

      # Append a message to the queue and persist it so drain survives a
      # resume. The hint shown in the queue pane depends on the current
      # phase (see `queue_hint`).
      private def enqueue_message(text : String, mode : String = "prompt", *, persist : Bool = true) : Nil
        @queue << QueuedMessage.new(text, mode)
        @on_persist_queued.try(&.call("turn.prompt", text)) if persist
        @messages << Message.new("system", "[Queued: #{truncate_preview(text)}]")
        invalidate_log_cache!
        @dirty = true
      end

      # Begin a turn for `text`: add to transcript, flip busy, spawn the
      # run_turn fiber. Called for the first message and for each drained
      # queued message.
      # Begin a turn for `text`: add to transcript, flip busy, spawn the
      # run_turn fiber. Called for the first message and for each drained
      # queued message.
      # `persisted` is false when the message was already written to the wire
      # log (e.g. it sat in the queue and `enqueue_message` persisted it); the
      # drain path sets it to avoid a duplicate `turn.prompt` record.
      private def start_turn(text : String, persisted : Bool = false) : Nil
        @messages << Message.new("user", text)
        # The welcome box is part of the Log zone history; do NOT hide it when
        # the first user message arrives. Removing it shrinks the log and
        # forces an unnecessary full repaint, besides violating the idea that
        # the log is append-only.
        @current_step = 0
        @step_tool_count = 0
        @agent_busy = true
        @status = "Thinking..."
        @spinner.start
        invalidate_log_cache!
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::Working))

        cb = @run_turn_cb || raise "run_turn_cb not initialized"
        spawn { cb.call(text, persisted) }
      end

      # Shift one queued message (FIFO) and start a fresh turn for it.
      # Called from `on_event(TurnEnd)` once the previous turn finishes and
      # the queue is non-empty. Recursive via the drain in `on_event` — each
      # turn-end pulls the next item until the queue empties.
      private def drain_next_queued : Nil
        return if @queue.empty?

        next_msg = @queue.shift
        @dispatch_pending = true

        # The tiny async hop lets the TurnEnd handler finish flipping phase
        # back to idle before we start the next turn (otherwise start_turn
        # would see agent_busy=true and re-queue the message).
        spawn(same_thread: true) do
          @dispatch_pending = false
          # Already persisted when enqueued — skip the duplicate write.
          start_turn(next_msg.text, persisted: true)
        end
      end

      private def truncate_preview(text : String) : String
        return text if text.size <= 40
        "#{text[0...40]}..."
      end

      # Public entry point for external systems (cron scheduler, background-task
      # completion) to deliver a prompt to the agent as a synthetic user message.
      # When busy, the message is queued (without a wire-log write — cron fires
      # are regenerated on resume from cron.json, and task notifications are
      # transient). When idle, a fresh turn is started (persisted: true so the
      # run_turn block skips writing a duplicate turn.prompt record).
      def deliver_external_prompt(text : String) : Nil
        return if text.strip.empty?
        if @agent_busy || @is_compacting || @defer_user_messages
          enqueue_message(text, "external", persist: false)
        else
          start_turn(text, persisted: true)
        end
      end

      TOOL_PREVIEW_LINES =   10
      TOOL_PREVIEW_CHARS = 1000

      # Normal TUI stores only a small preview of each tool result.
      # The full output is kept in the session JSONL and is viewable via /debug.
      private def tool_preview_text(text : String) : String
        return text if text.empty?
        return text if text.size <= TOOL_PREVIEW_CHARS && text.count('\n') <= TOOL_PREVIEW_LINES

        # Avoid scanning huge single-line outputs (e.g. a 50 MB file read).
        # Stop after the char budget or after the 11th newline.
        preview = String.build(capacity: TOOL_PREVIEW_CHARS + 64) do |s|
          line_count = 0
          chars = 0
          text.each_char do |c|
            if c == '\n'
              line_count += 1
              break if line_count > TOOL_PREVIEW_LINES
            end
            break if chars >= TOOL_PREVIEW_CHARS
            s << c
            chars += 1
          end
        end
        preview + "\n[... truncated; load session in /debug mode to expand ...]"
      end

      # Keep only a small preview of tool arguments in the TUI. The full args
      # are persisted in the session JSONL and viewable via /debug.
      private def tool_args_preview(name : String, args : String?) : String?
        return args if args.nil? || args.empty? || args.size <= TOOL_PREVIEW_CHARS

        begin
          parsed = JSON.parse(args)
          case name
          when "Edit"
            truncate_json_field(parsed, "old_string", "oldString")
            truncate_json_field(parsed, "new_string", "newString")
          when "Write"
            truncate_json_field(parsed, "content")
          end
          parsed.to_json
        rescue
          args
        end
      end

      private def truncate_json_field(parsed : JSON::Any, *keys : String)
        keys.each do |key|
          value = parsed[key]?
          next unless value
          text = value.as_s? || value.to_s
          next if text.size <= TOOL_PREVIEW_CHARS
          parsed.as_h[key] = JSON::Any.new(tool_preview_text(text))
        end
      end

      # The user-visible hint above the queue pane, mirroring the TS
      # queue-pane copy. Context-sensitive to the current phase.
      private def queue_hint : String
        if @is_compacting
          "will send after compaction"
        elsif @agent_busy
          "Ctrl+S steers now · Enter queues for next turn"
        else
          "will send next"
        end
      end

      # Ctrl+S handler. Three branches (mirrors TS `steerMessage`):
      #   - compacting/deferred  → enqueue (can't steer mid-compaction)
      #   - idle                 → send immediately (no turn to steer)
      #   - busy                 → inject into running turn via Agent#steer
      private def steer_or_queue(text : String) : Nil
        text = text.strip
        return if text.empty?

        if @is_compacting || @defer_user_messages
          enqueue_message(text)
          return
        end

        unless @agent_busy
          start_turn(text)
          return
        end

        # Busy: inject into the live turn.
        @on_steer.try(&.call(text))
        @on_persist_queued.try(&.call("turn.steer", text))
        @messages << Message.new("user", text)
        @messages << Message.new("system", "[Steered into running turn]")
        @dirty = true
      end

      # Ctrl+S with an empty editor but queued messages: the queue hint
      # ("Ctrl+S steers now") promises this drains the queue into the live
      # turn instead of waiting for turn-end drain. No-op unless a turn is
      # actually running; the queued entries were already persisted on
      # enqueue, so they are not re-persisted here.
      private def steer_queued : Nil
        return if @queue.empty?
        return unless @agent_busy
        return if @is_compacting || @defer_user_messages

        @queue.dup.each do |qm|
          @on_steer.try(&.call(qm.text))
          @messages << Message.new("user", qm.text)
        end
        @queue.clear
        @messages << Message.new("system", "[Queued messages steered into running turn]")
        @dirty = true
      end

      TIPS = [
        "tips.ctrl_steer",
        "tips.scroll_debug",
        "tips.enter_queues",
        "tips.help_commands",
        "tips.usage_queue",
        "tips.ctrl_exit",
      ]

      private def current_tip : String
        key = TIPS[(Time.utc.to_unix // 5) % TIPS.size]
        Hcode.t(key)
      end

      private def thinking_status : String
        step_word = @current_step == 1 ? "time" : "times"
        tool_word = @step_tool_count == 1 ? "tool" : "tools"
        "thinking #{@current_step} #{step_word}, call #{@step_tool_count} #{tool_word}"
      end

      private def finalize_streaming_thinking : Nil
        return if @streaming_thinking.empty?
        @messages << Message.new("thinking", @streaming_thinking)
        @streaming_thinking = ""
        invalidate_log_cache!
      end

      # Stop the spinner and, if it was active (meaning the transient
      # spinner-status line occupied one active-zone row), push a blank
      # "spacer" line into the log so the line counts stay balanced and
      # SyncBugsCount does not fire on the status line's disappearance.
      private def stop_spinner : Nil
        was_active = @spinner.active?
        @spinner.stop
        return unless was_active
        @messages << Message.new("spacer", "")
        invalidate_log_cache!
      end

      private def visible_len(s : String) : Int32
        CharWidth.visible_width(s)
      end

      private def detect_git_branch : String
        head_path = File.join(@work_dir, ".git", "HEAD")
        return "" unless File.exists?(head_path)
        head = File.read(head_path).strip
        if head.starts_with?("ref: refs/heads/")
          head["ref: refs/heads/".size..]
        else
          head[0...8]
        end
      rescue
        ""
      end
    end
  end
end
