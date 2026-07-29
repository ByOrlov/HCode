module Hcode
  module TUI
    struct ReadGroupEntry
      property tool_call_id : String
      property tool_args : String
      property tool_result : String?
      property is_error : Bool = false

      def initialize(@tool_call_id : String, @tool_args : String)
      end

      def profiled_bytes : Int64
        total = @tool_call_id.profiled_bytes + @tool_args.profiled_bytes
        total += @tool_result.try(&.profiled_bytes) || 0_i64
        total
      end
    end

    struct Message
      property role : String
      property content : String
      property tool_call_id : String = ""
      property tool_name : String?
      property tool_args : String?
      property tool_result : String?
      property tool_display : Tools::ToolDisplay? = nil
      property is_error : Bool = false
      property? expanded : Bool = false
      property step : Int32 = 0
      property read_group : Array(ReadGroupEntry)?
      # Used only by `role == "step_summary"` messages.
      property thinking_count : Int32 = 0
      property tool_count : Int32 = 0
      # Plan-box: when a tool result carries an ExitPlanMode plan (approved,
      # auto-approved, or rejected), the plan body is lifted out of the raw
      # result text and rendered as a bordered box — mirrors TS PlanBoxComponent.
      property plan_path : String?
      property plan_kind : String = ""  # "approved" | "auto_approved" | "rejected"
      # Compaction block: a transcript entry that blinks while compaction is
      # in flight, then settles into a "complete (N → M tokens)" summary.
      # Mirrors TS `CompactionComponent`. Ctrl-O expands/collapses the
      # summary inline (reuses the generic `expanded` flag).
      property compaction_state : String = ""  # "" | "running" | "done" | "cancelled"
      property tokens_before : Int32? = nil
      property tokens_after : Int32? = nil
      property summary : String = ""
      property tip : String = ""
      # Optional RAM-usage line (set by --ram). Rendered inside the tool
      # block right under the result preview, dim+italic so it visually
      # separates from the actual tool output.
      property ram_line : String? = nil

      def initialize(@role : String, @content : String = "")
      end

      # Deep byte size of this transcript entry — the strings it carries.
      # `tool_display` (diff before/after) is included when present.
      def profiled_bytes : Int64
        total = @role.profiled_bytes + @content.profiled_bytes
        total += @tool_call_id.profiled_bytes unless @tool_call_id.empty?
        total += @tool_name.try(&.profiled_bytes) || 0_i64
        total += @tool_args.try(&.profiled_bytes) || 0_i64
        total += @tool_result.try(&.profiled_bytes) || 0_i64
        total += @summary.profiled_bytes unless @summary.empty?
        total += @tip.profiled_bytes unless @tip.empty?
        total += @ram_line.try(&.profiled_bytes) || 0_i64
        if d = @tool_display
          total += d.before.try(&.profiled_bytes) || 0_i64
          total += d.after.try(&.profiled_bytes) || 0_i64
        end
        if group = @read_group
          total += group.sum(&.profiled_bytes)
        end
        total
      end
    end

    struct ApprovalRequest
      property tool_name : String
      property args : String
      property danger : String?

      def initialize(@tool_name : String, @args : String, @danger : String?)
      end
    end

    # A message typed while the agent is mid-turn. Mirrors the TS
    # `QueuedMessage` (mode 'prompt' = normal message, 'bash' = queued shell
    # command — not yet used). Drained FIFO on turn end; `Ctrl+S` (steer)
    # injects it into the *current* turn instead, via `Agent#steer`.
    struct QueuedMessage
      property text : String
      property mode : String # "prompt" | "bash"

      def initialize(@text : String, @mode : String = "prompt")
      end
    end

    class App
      PASTE_MARKER_RE           = /\[paste #\d+(?: \+\d+ lines| \d+ chars)?\]/
      THINKING_PREVIEW_LINES    = 2
      THINKING_INDENT           = "  "
      STATUS_BULLET             = "● "
      USER_BULLET               = "✨ "
      DEFAULT_KEEP_RECENT_STEPS = 30
      KEEP_RECENT_STEPS_ENV     = "HCODE_TUI_KEEP_RECENT_STEPS"
      # Cross-turn trimming: turns older than this count are collapsed into
      # a single `step_summary` per turn (thinking/tool counts only). Caps
      # linear growth of `@messages` in long sessions — see
      # plans/TOOLS-LEAKS.md §B1. Env: HCODE_TUI_KEEP_RECENT_TURNS.
      DEFAULT_KEEP_RECENT_TURNS = 50
      KEEP_RECENT_TURNS_ENV     = "HCODE_TUI_KEEP_RECENT_TURNS"

      @terminal : Terminal
      @input : Input
      @editor : Editor
      @spinner : Spinner
      @theme : Theme
      @messages : Array(Message) = [] of Message
      @previous_lines : Array(String) = [] of String
      @previous_viewport_top : Int32 = 0
      @hardware_cursor_row : Int32 = 0
      @max_lines_rendered : Int32 = 0
      @last_cols : Int32 = 0
      @last_rows : Int32 = 0
      @cursor_line : Int32 = 0
      # Cursor position within the editor box, resolved against the soft-wrapped
      # layout (computed in `render_editor_box`, read in `position_cursor`).
      # `visual_row` is the 0-based content row; `visual_col` is the visible
      # column offset from the content start on that row.
      @editor_cursor_visual_row : Int32 = 0
      @editor_cursor_visual_col : Int32 = 0
      @first_render : Bool = true
      @streaming_text : String = ""
      @streaming_thinking : String = ""
      @streaming_tool : String?
      @pasted_block : String?
      @pasted_lines : Int32 = 0
      @status : String = ""
      @model : String = "kimi-for-coding"
      @provider_name : String = "moonshot"
      @permission_mode : String = "manual"
      @context_percent : Float64 = 0.0
      @context_tokens : Int32 = 0
      @max_context_tokens : Int32 = 262144
      @running : Bool = true
      @agent_busy : Bool = false
      @is_compacting : Bool = false
      @defer_user_messages : Bool = false
      @compaction_msg : Message? = nil
      # Set during the brief window between "shifted a queued message out of
      # the array" and "actually started its turn" so a queued-message
      # dispatcher doesn't see an empty queue + idle phase and race itself.
      @dispatch_pending : Bool = false
      @run_turn_cb : (String, Bool -> Nil)?
      # Plan mode mirrors TS: while on, tools that mutate state are blocked
      # and the agent only researches. Toggled via `/plan` or `EnterPlanMode`.
      @plan_mode : Bool = false
      @queue : Array(QueuedMessage) = [] of QueuedMessage
      @spin_phase : Int32 = 0
      @dirty : Bool = true
      @last_render : Time::Span = Time.monotonic
      @scroll_offset : Int32 = 0
      @exit_confirm : Bool = false
      @exit_key : String = "CTRL+C"
      @current_step : Int32 = 0
      @step_tool_count : Int32 = 0
      @pending_read_group : Message? = nil
      property keep_recent_steps : Int32 = DEFAULT_KEEP_RECENT_STEPS
      property keep_recent_turns : Int32 = DEFAULT_KEEP_RECENT_TURNS

      # Command state
      @show_command_hints : Bool = false
      @command_hints : Array(CommandInfo) = [] of CommandInfo
      @command_hint_selected : Int32 = 0
      @export_path : String?
      @on_compact : (-> Nil)?
      @on_clear : (-> Nil)?
      @on_undo : (-> Nil)?
      @on_cancel : (-> Nil)?
      @on_new_session : (-> Nil)?
      @on_export : (String -> Nil)?
      @on_provider_change : (String -> Bool)?
      @on_model_change : (String -> Bool)?
      @on_fetch_models : (-> Array(String))?
      @on_resume_session : (String -> Nil)?
      @on_fork : (-> Nil)?
      @on_archive : (-> Nil)?
      @on_rename : (String -> Nil)?
      @on_debug : (-> Nil)?

      # Setup wizard state (first-run provider configuration). When
      # `@setup_mode` is true the editor input is intercepted: the provider
      # selector drives the first step, subsequent submits feed the wizard,
      # and completion invokes `on_setup_complete`.
      @setup_mode : Bool = false
      @wizard : Setup::Wizard? = nil
      property? setup_mode : Bool = false
      property wizard : Setup::Wizard? = nil
      property on_setup_complete : (Setup::Wizard -> Nil)? = nil

      # Approval state
      @approval_pending : ApprovalRequest?
      @approval_channel = Channel(Permission::ApprovalChoice).new
      # Notification subsystem: owns the current agent status and fans every
      # real transition out to the dispatcher. nil when notifications are
      # disabled (no dispatcher wired up) → transitions become no-ops.
      @status_tracker : Notify::StatusTracker?
      @markdown : Markdown
      @provider_list : SelectList
      @model_list : SelectList
      @session_list : SelectList
      @permission_list : SelectList
      @effort_list : SelectList
      @theme_list : SelectList
      @question_dialog : QuestionDialog
      @undo_dialog : UndoDialog
      @tasks_browser : TasksBrowser
      @help_panel : HelpPanel
      @session_entries : Array(Session::SessionEntry) = [] of Session::SessionEntry
      @session_picker_mode : Symbol = :resume
      @show_welcome : Bool = true
      @session_id : String = ""
      @work_dir : String = ""
      @home : String = ENV["HOME"]? || "/tmp"
      @git_branch : String = ""

      property model : String
      property provider_name : String
      property permission_mode : String
      property context_percent : Float64
      property context_tokens : Int32
      property max_context_tokens : Int32
      property session_id : String
      property work_dir : String
      property home : String
      property git_branch : String
      property on_compact : (-> Nil)?
      property on_clear : (-> Nil)?
      property on_undo : (-> Nil)?
      property on_cancel : (-> Nil)?
      property on_new_session : (-> Nil)?
      property on_export : (String -> Nil)?
      property on_provider_change : (String -> Bool)?
      property on_model_change : (String -> Bool)?
      property on_fetch_models : (-> Array(String))?
      property on_resume_session : (String -> Nil)?
      property on_fork : (-> Nil)?
      property on_archive : (-> Nil)?
      property on_rename : (String -> Nil)?
      property on_debug : (-> Nil)?
      property on_persist_queued : (String, String -> Nil)?
      property on_steer : (String -> Nil)?
      # Thinking-effort selectors (off/low/medium/high). Effort strings are
      # provider-specific in shape but the TUI uses the neutral words.
      property on_get_effort : (-> String)?
      property on_set_effort : (String -> Nil)?
      # Plan-mode toggle: receives the next desired state, returns true if it
      # was applied (false → not wired up / not supported by this provider).
      property on_plan_mode : (Bool -> Bool)?
      # Returns the current TodoList items (or nil if the tool isn't loaded).
      # The TUI renders these in a panel above the editor when non-empty.
      @on_fetch_todos : (-> Array({String, String})?)? = nil
      property on_fetch_todos : (-> Array({String, String})?)?
      # Clear the TodoList tool's state (only meaningful when the agent has
      # registered a TodoList tool).
      @on_clear_todos : (-> Nil)? = nil
      property on_clear_todos : (-> Nil)?
      # Send a feedback message to the team. Backed by an HTTP POST when wired
      # up; otherwise the local `/feedback` handler appends to a log file.
      @on_feedback : (String -> Nil)? = nil
      property on_feedback : (String -> Nil)?
      # Reload `config.toml` + session state without restarting the process.
      @on_reload : (-> Nil)? = nil
      property on_reload : (-> Nil)?
      # Returns the on-disk directory for the current session (where
      # `wire.jsonl` / `state.json` live). Used by `/export-debug-zip`.
      @on_session_dir : (-> String?)? = nil
      property on_session_dir : (-> String?)?
      # Logout: clear stored credentials (API key from config.toml).
      @on_logout : (-> Nil)? = nil
      property on_logout : (-> Nil)?
      # Undo N turns (count is the selected turn's index). When wired, opens
      # the undo selector; falls back to single-turn `on_undo`.
      @on_undo_count : (Int32 -> Nil)? = nil
      property on_undo_count : (Int32 -> Nil)?
      # Returns user-turn candidates that can be undone, oldest→newest.
      # Each entry: {count, input, label}. nil = not wired up → fallback path.
      @on_fetch_undo_choices : (-> Array({Int32, String, String})?)? = nil
      property on_fetch_undo_choices : (-> Array({Int32, String, String})?)?
      # Tasks browser: data source for the background-task list.
      @on_fetch_tasks : (-> Array(Tools::AgentTaskInfo))? = nil
      property on_fetch_tasks : (-> Array(Tools::AgentTaskInfo))?
      # Tasks browser: stop a task by id (user-confirmed).
      @on_stop_task : (String -> Nil)? = nil
      property on_stop_task : (String -> Nil)?
      # Tasks browser: open the full output for a task.
      @on_open_task_output : (String -> Nil)? = nil
      property on_open_task_output : (String -> Nil)?
      # Persist a queued message to JSONL (so drain survives resume). The
      # wire event type is the argument: "turn.prompt" or "turn.steer".
      property on_persist_queued : (String, String -> Nil)?
      # Steer: inject `text` into the running turn (Agent#steer).
      property on_steer : (String -> Nil)?

      def initialize(
        @terminal : Terminal = Terminal.current,
        @theme : Theme = Theme.dark,
        dispatcher : Notify::Dispatcher? = nil,
      )
        @input = Input.new
        @editor = Editor.new("")
        @editor.fg_color = @theme.colors.text
        @editor.accent_color = @theme.colors.primary
        @spinner = Spinner.new
        @markdown = Markdown.new(@theme)
        @provider_list = SelectList.new([] of String, @theme)
        @model_list = SelectList.new([] of String, @theme)
        @session_list = SelectList.new([] of String, @theme)
        @permission_list = SelectList.new([] of String, @theme)
        @effort_list = SelectList.new([] of String, @theme)
        @theme_list = SelectList.new([] of String, @theme)
        @question_dialog = QuestionDialog.new(@theme)
        @undo_dialog = UndoDialog.new(@theme)
        @tasks_browser = TasksBrowser.new(@theme)
        @help_panel = HelpPanel.new(@theme)
        @work_dir = Dir.current
        @git_branch = detect_git_branch
        @keep_recent_steps = read_keep_recent_steps
        @keep_recent_turns = read_keep_recent_turns
        # Wire the notification dispatcher into a StatusTracker. The tracker
        # lives on the App so UI transitions (start_turn, turn_end, approval)
        # can drive it directly.
        if disp = dispatcher
          @status_tracker = Notify::StatusTracker.new { |t| disp.on_transition(t) }
        end
      end

      # Enter setup mode: show the wizard transcript and open the provider
      # selector. Called once at first-run before the normal TUI loop starts.
      def start_setup : Nil
        @setup_mode = true
        @wizard = Setup::Wizard.new
        @show_welcome = false
        @messages << Message.new("system",
          "Welcome to HCode. Choose your provider to get started.")
        @status = "Setup: select provider"
        open_setup_provider_selector
        @dirty = true
      end

      private def open_setup_provider_selector : Nil
        items = Setup::Wizard.choices.map(&.label)
        @provider_list.show("Select provider", items)
        @provider_list.selected = 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_setup_provider_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @provider_list.handle_input(key)
          @dirty = true
        when .enter?
          idx = @provider_list.selected
          choices = Setup::Wizard.choices
          choice = choices[idx]? || choices.first
          @provider_list.hide
          @dirty = true

          wizard = @wizard
          return unless wizard

          wizard.select_provider(choice.name)
          @provider_name = choice.name
          @messages << Message.new("user", choice.label)

          if wizard.step == Setup::Wizard::Step::Endpoint
            # Keyless provider: jump straight to endpoint, but still show a
            # transcript entry so the user knows why no key was asked.
            @messages << Message.new("system",
              "No API key needed for #{choice.name}.")
          end
          advance_setup_step
        when .escape?
          @provider_list.hide
          @dirty = true
        end
      end

      private def advance_setup_step : Nil
        wizard = @wizard
        return unless wizard

        if wizard.done?
          finish_setup
          return
        end

        @status = "Setup: #{wizard.step.to_s.downcase}"
        @editor.clear
        @dirty = true
      end

      private def finish_setup : Nil
        wizard = @wizard
        return unless wizard

        config_msg = "Provider: #{wizard.provider_name}"
        config_msg += " | Model: #{wizard.model}" if wizard.model
        @messages << Message.new("system", "Configuration saved. #{config_msg}")
        @messages << Message.new("system", "Starting HCode...")
        @status = ""
        @setup_mode = false
        @dirty = true

        if cb = @on_setup_complete
          cb.call(wizard)
        end
      end

      private def submit_setup_text(text : String) : Nil
        wizard = @wizard
        return unless wizard

        # Echo what the user entered (mask API keys).
        if wizard.step == Setup::Wizard::Step::Credentials
          masked = text.empty? ? "(skipped)" : "#{"•" * {text.size, 8}.min}"
          @messages << Message.new("user", masked)
        else
          display = text.empty? ? "(default)" : text
          @messages << Message.new("user", display)
        end

        wizard.submit_text(text)
        advance_setup_step
      end

      def run(initial_prompt : String? = nil, &run_turn : String, Bool -> Nil) : Nil
        @terminal.raw!
        @terminal.refresh_size
        @run_turn_cb = run_turn

        Signal::INT.trap do
          if @agent_busy
            @status = "Cancelling..."
            @dirty = true
            @on_cancel.try(&.call)
          else
            @running = false
            # Move cursor to end and print newline before restoring
            if @cursor_line > 0
              print "\r"
            end
            print "\n"
            STDOUT.flush
            @terminal.restore!
            print "\n"
            exit(0)
          end
        end

        Signal::WINCH.trap do
          @terminal.refresh_size
          @first_render = true
          @dirty = true
        end

        render

        # Auto-submit an initial prompt (used by mock demo tasks) so the user
        # immediately sees streaming without typing anything.
        if ip = initial_prompt
          submit_message(ip)
        end

        while @running
          key = @input.read_key

          if key
            handle_key(key)
          end

          now = Time.monotonic
          elapsed = (now - @last_render).total_milliseconds

          if @agent_busy && elapsed >= 80
            @spin_phase += 1
            @dirty = true
          end

          # During active streaming (thinking or text), render immediately on
          # dirty — bypassing the 80ms spinner throttle — so the user sees
          # progressive content updates instead of only the finalized block.
          streaming = !@streaming_thinking.empty? || !@streaming_text.empty?
          if @dirty && (!@agent_busy || streaming || elapsed >= 80)
            render
            @dirty = false
            @last_render = now
          end

          sleep 20.milliseconds unless key
        end

        @terminal.restore!
      end

      # Restore the terminal out of raw mode. Used by /debug before dumping the
      # full session transcript to stdout and exiting.
      def restore_terminal : Nil
        @terminal.restore!
      end

      def add_message(role : String, content : String) : Nil
        @messages << Message.new(role, content)
      end

      # Deep byte size of the on-screen transcript — the TUI-side duplicate of
      # the conversation history. Used by the `/memory` profiler.
      def profiled_bytes : Int64
        @messages.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @messages.size
      end

      def render_buffer_bytes : Int64
        @previous_lines.sum(&.profiled_bytes)
      end

      def render_buffer_count : Int32
        @previous_lines.size
      end

      def queue_bytes : Int64
        @queue.sum(&.text.profiled_bytes)
      end

      def queue_count : Int32
        @queue.size
      end

      # Rebuild the visible TUI transcript from a replayed context memory.
      # Called after session resume/fork so the on-screen conversation matches
      # the agent's internal state. Streaming-only metadata (thinking blocks,
      # step summaries) is not recoverable from the wire log and is omitted.
      def load_transcript_from(memory : Context::Memory) : Nil
        @messages.clear
        @streaming_text = ""
        @streaming_thinking = ""
        @streaming_tool = nil
        @current_step = 0

        memory.history.each do |cm|
          msg = cm.message
          case cm.origin
          when .injection?
            next
          when .compaction_summary?
            @messages << Message.new("system", "[compacted] #{msg.content.to_s}")
            next
          end

          case msg.role
          when "user"
            @messages << Message.new("user", msg.content.to_s)
          when "assistant"
            if tcs = msg.tool_calls
              tcs.each do |tc|
                m = Message.new("tool", "")
                m.tool_call_id = tc.id
                m.tool_name = tc.name
                m.tool_args = tc.arguments
                m.step = @current_step
                @messages << m
              end
            end
            unless (text = msg.content).to_s.empty?
              @messages << Message.new("assistant", text.to_s)
            end
          when "tool"
            attach_tool_result(msg.tool_call_id.to_s, msg.content.to_s)
          when "system"
            @messages << Message.new("system", msg.content.to_s) unless msg.content.to_s.empty?
          end
        end

        @dirty = true
      end

      private def attach_tool_result(tool_call_id : String, result : String) : Nil
        i = @messages.size - 1
        while i >= 0
          m = @messages[i]
          if m.role == "tool" && m.tool_call_id == tool_call_id
            m.tool_result = result
            @messages[i] = m
            return
          end
          i -= 1
        end
      end

      def show_interrupted(message : String = "Interrupted by user") : Nil
        finalize_streaming_thinking
        # Flush any in-flight streaming text into a permanent assistant message
        # so it doesn't disappear when we reset the streaming buffer.
        unless @streaming_text.empty?
          @messages << Message.new("assistant", @streaming_text)
          @streaming_text = ""
        end
        @spinner.stop
        @messages << Message.new("status", message)
        @dirty = true
      end

      def on_event(event : Loop::Event) : Nil
        case event.type
        when .step_begin?
          @current_step = event.step
          @spinner.start
          @status = thinking_status
          @scroll_offset = 0
        when .text_delta?
          finalize_streaming_thinking
          @streaming_text += event.text
          @status = thinking_status
          @scroll_offset = 0
        when .thinking_delta?
          @streaming_thinking += event.text
          @status = "thinking..."
          @scroll_offset = 0
        when .assistant_text?
          finalize_streaming_thinking
          unless @streaming_text.empty?
            @messages << Message.new("assistant", @streaming_text)
            @streaming_text = ""
          end
          @spinner.stop
          @status = ""
        when .tool_call_start?
          finalize_streaming_thinking
          unless @streaming_text.empty?
            @messages << Message.new("assistant", @streaming_text)
            @streaming_text = ""
          end
          @spinner.stop
          @step_tool_count += 1

          if event.tool_name == "Read" && (group = @pending_read_group) && group.step == @current_step
            group.read_group ||= [] of ReadGroupEntry
            group.read_group.not_nil! << ReadGroupEntry.new(event.tool_call_id, event.tool_args)
          else
            msg = Message.new("tool", "")
            msg.tool_call_id = event.tool_call_id
            msg.tool_name = event.tool_name
            msg.tool_args = tool_args_preview(event.tool_name, event.tool_args)
            msg.step = @current_step
            @messages << msg
            @pending_read_group = event.tool_name == "Read" ? msg : nil
          end

          @streaming_tool = event.tool_name
          @status = thinking_status
        when .tool_result?
          # Results for parallel tool calls can arrive out of order, so scan
          # backward for the matching tool message instead of assuming the last
          # one is the target. Message is a struct, so updated values must be
          # reassigned into the array.
          i = @messages.size - 1
          while i >= 0
            msg = @messages[i]
            if msg.role == "tool"
              if group = msg.read_group
                if eidx = group.index { |e| e.tool_call_id == event.tool_call_id }
                  entry = group[eidx]
                  entry.tool_result = tool_preview_text(event.text)
                  entry.is_error = event.is_error
                  group[eidx] = entry
                  msg.read_group = group
                  @messages[i] = msg
                  break
                end
              elsif msg.tool_call_id == event.tool_call_id
                msg.tool_result = tool_preview_text(event.text)
                msg.is_error = event.is_error
                # The full structured display (e.g. Edit diff) can be large.
                # /debug has the full output; the TUI renders from the preview.
                msg.tool_display = nil
                # RAM-usage line attached by --ram; rendered inside this
                # block, right under the result preview.
                msg.ram_line = event.ram_line
                @messages[i] = msg
                break
              end
            end
            i -= 1
          end
          @streaming_tool = nil
          @status = thinking_status
          inject_plan_if_any(event.text)
          merge_turn_steps
        when .info?
          @status = event.text
          # Compaction start message ("Context near limit, triggering compaction...")
          # sets the compacting flag; the completion message
          # ("Context compacted (N → M messages)") clears it.
          if event.text.includes?("compacting") || event.text.includes?("compaction")
            @is_compacting = true
          elsif event.text.includes?("compacted")
            @is_compacting = false
            @spinner.stop
          end
        when .compaction_started?
          @is_compacting = true
          @defer_user_messages = true
          @status = "Compacting context..."
          @scroll_offset = 0
          msg = Message.new("compaction", "")
          msg.compaction_state = "running"
          msg.tip = event.tip || ""
          msg.tokens_before = event.tokens_before
          @compaction_msg = msg
          @messages << msg
        when .compaction_completed?
          @is_compacting = false
          @defer_user_messages = false
          @spinner.stop
          @status = ""
          # Update the most recent running compaction block in place.
          if cmsg = @compaction_msg
            cmsg.compaction_state = "done"
            cmsg.tokens_before = event.tokens_before
            cmsg.tokens_after = event.tokens_after
            cmsg.summary = event.summary || ""
          else
            i = @messages.size - 1
            while i >= 0
              m = @messages[i]
              if m.role == "compaction" && m.compaction_state == "running"
                m.compaction_state = "done"
                m.tokens_before = event.tokens_before
                m.tokens_after = event.tokens_after
                m.summary = event.summary || ""
                @messages[i] = m
                break
              end
              i -= 1
            end
          end
          @compaction_msg = nil
        when .compaction_cancelled?
          @is_compacting = false
          @defer_user_messages = false
          @spinner.stop
          @status = ""
          if cmsg = @compaction_msg
            cmsg.compaction_state = "cancelled"
          else
            i = @messages.size - 1
            while i >= 0
              m = @messages[i]
              if m.role == "compaction" && m.compaction_state == "running"
                m.compaction_state = "cancelled"
                @messages[i] = m
                break
              end
              i -= 1
            end
          end
          @compaction_msg = nil
        when .error?
          @messages << Message.new("error", event.text)
          @spinner.stop
          @status = ""
        when .turn_end?
          # Turn finished (normal, errored, or cancelled). Reset busy state
          # and drain the next queued message if any. The TUI is the single
          # owner of the busy/idle phase so this is the only place busy flips
          # back to false — run_turn itself runs in a detached fiber and
          # cannot safely touch @agent_busy on completion.
          @agent_busy = false
          @is_compacting = false
          @defer_user_messages = false
          @spinner.stop
          @status = ""
          @status_tracker.try(&.transition!(Notify::AgentStatus::Done, "Turn complete"))
          @status_tracker.try(&.transition!(Notify::AgentStatus::Idle))

          # A cancelled turn ends the dispatch chain: drop queued messages
          # so they don't leak into the next prompt the user types fresh.
          if event.is_error
            unless @queue.empty?
              @queue.clear
              @messages << Message.new("system", "[Queue cleared on interrupt]")
            end
          end

          # Drain the next queued message if the user queued one during the
          # finished turn. Skipped during the dispatch-pending gap.
          if (cb = @run_turn_cb) && !@dispatch_pending
            drain_next_queued
          end
        end

        @dirty = true
      end

      def request_approval(tool_name : String, args : String, danger : String?) : Permission::ApprovalChoice
        @approval_pending = ApprovalRequest.new(tool_name, args, danger)
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::InputRequired,
                                          "Approval required", tool_name))
        select
        when choice = @approval_channel.receive
          @approval_pending = nil
          @dirty = true
          @status_tracker.try(&.transition!(Notify::AgentStatus::Working))
          choice
        end
      end

      # Launch a structured multi-question prompt. Mirrors TS
      # `reverse-rpc/question-adapter.ts` mounting a QuestionDialogComponent
      # and awaiting the user's answers. Returns the answers map
      # (question text → answer), empty when the user dismissed the dialog.
      def request_questions(questions : Array(Tools::QuestionItem),
                            on_toggle_tool_output : (-> Nil)? = nil) : Hash(String, String)
        # Capacity 1 so the dialog's callback can `send` without rendezvous
        # — otherwise `send` inside `handle_input` would deadlock waiting for
        # the `receive` that can only run after handle_input returns.
        received = Channel(Hash(String, String)).new(1)
        @question_dialog.show(questions, ->(answers : Hash(String, String)) do
          received.send(answers)
          nil
        end, on_toggle_tool_output)
        @dirty = true
        received.receive
      end

      private def handle_key(key : KeyEvent) : Nil
        if @exit_confirm
          case key.key
          when .ctrl_c?
            @running = false if @exit_key == "CTRL+C"
          when .ctrl_d?
            @running = false if @exit_key == "CTRL+D"
          when .escape?
            @exit_confirm = false
            @dirty = true
          else
            @exit_confirm = false
            @dirty = true
          end
          return
        end

        if @approval_pending
          handle_approval_key(key)
          return
        end

        # Setup wizard: intercept all keys while the wizard is active. The
        # provider selector handles its own input; other steps read the editor.
        if @setup_mode
          if @provider_list.visible?
            handle_setup_provider_key(key)
            return
          end
          case key.key
          when .enter?
            unless @editor.empty?
              text = @editor.submit!
              submit_setup_text(text)
            end
          when .escape?
            @editor.clear
          else
            @editor.handle_input(key)
          end
          @dirty = true
          return
        end

        if @tasks_browser.visible?
          @tasks_browser.rows = @terminal.rows
          @tasks_browser.handle_input(key)
          @dirty = true
          return
        end

        if @undo_dialog.visible?
          @undo_dialog.handle_input(key)
          @dirty = true
          return
        end

        if @question_dialog.visible?
          @question_dialog.handle_input(key)
          @dirty = true
          return
        end

        if @help_panel.visible?
          handle_help_key(key)
          return
        end

        if @provider_list.visible?
          handle_provider_key(key)
          return
        end

        if @model_list.visible?
          handle_model_key(key)
          return
        end

        if @session_list.visible?
          handle_session_key(key)
          return
        end

        if @permission_list.visible?
          handle_permission_list_key(key)
          return
        end

        if @effort_list.visible?
          handle_effort_list_key(key)
          return
        end

        if @theme_list.visible?
          handle_theme_list_key(key)
          return
        end

        case key.key
        when .ctrl_c?
          if @agent_busy
            @status = "Cancelling..."
            @dirty = true
            @on_cancel.try(&.call)
          else
            @exit_confirm = true
            @exit_key = "CTRL+C"
            @dirty = true
          end
        when .ctrl_d?
          @exit_confirm = true
          @exit_key = "CTRL+D"
          @dirty = true
        when .enter?
          if pasted = @pasted_block
            editor_text = @editor.text
            if editor_text.includes?(paste_marker)
              final_text = editor_text.sub(paste_marker, pasted)
              @pasted_block = nil
              @pasted_lines = 0
              @editor.clear

              if final_text.starts_with?('/')
                handle_slash_command(final_text)
              else
                submit_message(final_text)
              end
            elsif !@editor.empty?
              text = @editor.submit!

              if text.starts_with?('/')
                handle_slash_command(text)
              else
                submit_message(text)
              end
            end
          elsif !@editor.empty?
            text = @editor.submit!

            if text.starts_with?('/')
              handle_slash_command(text)
            else
              submit_message(text)
            end
          end
        when .ctrl_s?
          if !@editor.empty?
            text = @editor.submit!
            steer_or_queue(text)
          end
        when .ctrl_g?
          handle_external_editor
        when .up?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected - 1 + @command_hints.size) % @command_hints.size
            @dirty = true
          elsif @editor.empty?
            @scroll_offset += 1
            @dirty = true
          else
            @editor.handle_input(key)
          end
        when .down?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected + 1) % @command_hints.size
            @dirty = true
          elsif @editor.empty?
            @scroll_offset -= 1 if @scroll_offset > 0
            @dirty = true
          else
            @editor.handle_input(key)
          end
        when .tab?
          if @show_command_hints && @command_hints.size > 0
            selected = @command_hints[@command_hint_selected]
            @editor.set("#{selected.name} ")
            @show_command_hints = false
            @dirty = true
          end
        when .escape?
          if @agent_busy
            @status = "Cancelling..."
            @dirty = true
            @on_cancel.try(&.call)
          elsif @pasted_block
            cancel_pasted_block
          elsif !@editor.empty?
            @editor.clear
          end
        when .paste?
          if text = key.text
            paste_lines = text.count('\n') + 1
            if paste_lines > 10 || text.size > 1000
              @pasted_block = text
              @pasted_lines = paste_lines
              @editor.insert_text(paste_marker)
            else
              @editor.insert_text(text)
            end
            update_command_hints
          end
        when .ctrl_e?
          if pasted = @pasted_block
            editor_text = @editor.text
            if editor_text.includes?(paste_marker)
              @editor.set(editor_text.sub(paste_marker, pasted))
            end
            @pasted_block = nil
            @pasted_lines = 0
          end
        when .backspace?
          if @pasted_block
            cancel_pasted_block
          else
            @editor.handle_input(key)
          end
        when .delete?
          if @pasted_block
            cancel_pasted_block
          else
            @editor.handle_input(key)
          end
        else
          @editor.handle_input(key)
          update_command_hints
        end

        @dirty = true
      end

      private def handle_approval_key(key : KeyEvent) : Nil
        case key.key
        when .char?
          case key.char
          when 'y', 'Y'
            @approval_channel.send(Permission::ApprovalChoice::ApproveOnce)
          when 's', 'S'
            @approval_channel.send(Permission::ApprovalChoice::ApproveSession)
          when 'n', 'N'
            @approval_channel.send(Permission::ApprovalChoice::Deny)
          end
        when .escape?
          @approval_channel.send(Permission::ApprovalChoice::Deny)
        end
      end

      private def paste_marker : String
        "[paste #1 +#{@pasted_lines} lines]"
      end

      private def cancel_pasted_block : Nil
        return unless @pasted_block

        editor_text = @editor.text
        @editor.set(editor_text.sub(PASTE_MARKER_RE, ""))
        @pasted_block = nil
        @pasted_lines = 0
      end

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
      private def enqueue_message(text : String, mode : String = "prompt") : Nil
        @queue << QueuedMessage.new(text, mode)
        @on_persist_queued.try(&.call("turn.prompt", text))
        @messages << Message.new("system", "[Queued: #{truncate_preview(text)}]")
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
        @current_step = 0
        @step_tool_count = 0
        @agent_busy = true
        @status = "Thinking..."
        @scroll_offset = 0
        @spinner.start
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::Working))

        spawn { @run_turn_cb.not_nil!.call(text, persisted) }
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

      private def update_command_hints : Nil
        text = @editor.text
        if text.starts_with?('/') && !text.includes?(' ')
          matches = CommandRegistry.match(text)
          if matches.size > 0
            @show_command_hints = true
            @command_hints = matches
            @command_hint_selected = {@command_hint_selected, matches.size - 1}.min
          else
            @show_command_hints = false
          end
        else
          @show_command_hints = false
        end
      end

      private def handle_external_editor : Nil
        editor_cmd = ENV["EDITOR"]? || ENV["VISUAL"]? || "vim"
        tmp_dir = ENV["TMPDIR"]? || "/tmp"
        tmp_file = File.join(tmp_dir, "hcode-edit-#{Random::Secure.hex(4)}.md")
        File.write(tmp_file, @editor.text)

        @terminal.restore!

        status = Process.run("#{editor_cmd} #{tmp_file}", shell: true)

        content = File.exists?(tmp_file) ? File.read(tmp_file) : ""
        File.delete(tmp_file) rescue nil

        @terminal.raw!
        @editor.set(content.strip)
        @dirty = true
      end

      # Copy `text` to the system clipboard using whichever native helper is
      # available on this OS. Falls back silently — a missing helper should
      # never break the session. Mirrors TS `utils/clipboard.ts`.
      private def copy_to_clipboard(text : String) : Nil
        cmd = clipboard_command
        return unless cmd
        begin
          io = IO::Memory.new(text)
          Process.run(cmd[0], cmd[1], input: io, output: Process::Redirect::Close, error: Process::Redirect::Close)
        rescue
        end
      end

      # Resolve the first available clipboard helper as `{program, [args]}`.
      # Order mirrors the TS version (pbcopy → wl-copy → xclip → xsel).
      private def clipboard_command : Tuple(String, Array(String))?
        candidates = [
          {"pbcopy", [] of String},
          {"wl-copy", [] of String},
          {"xclip", ["-selection", "clipboard"]},
          {"xsel", ["--clipboard", "--input"]},
        ]
        candidates.each do |c|
          if Process.find_executable(c[0])
            return c
          end
        end
        nil
      end

      # Bundle the current session (wire.jsonl, state.json) plus a manifest
      # (hcode version, provider, model, session id) into a tar.gz the user
      # can share for debugging. Output goes to the OS temp dir. Returns nil
      # when `tar` is unavailable or the session dir is unknown. Mirrors TS
      # `handleExportDebugZipCommand` (which additionally includes the global
      # log — we add the ~/.hcode log file too when it exists).
      private def export_debug_bundle : String?
        return nil if @session_id.empty?
        return nil unless session_dir = @on_session_dir.try(&.call)
        return nil unless Process.find_executable("tar")

        tmp_dir = ENV["TMPDIR"]? || "/tmp"
        bundle_dir = File.join(tmp_dir, "hcode-debug-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(bundle_dir)

        # Manifest with version / provider / model / timestamps.
        manifest_path = File.join(bundle_dir, "manifest.txt")
        manifest = String.build do |s|
          s << "hcode_version=#{Hcode::VERSION}\n"
          s << "build=#{Hcode.build_date || "dev"}\n"
          s << "crystal=#{Crystal::VERSION}\n"
          s << "session_id=#{@session_id}\n"
          s << "provider=#{@provider_name}\n"
          s << "model=#{@model}\n"
          s << "permission=#{@permission_mode}\n"
          s << "exported_at=#{Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")}\n"
        end
        File.write(manifest_path, manifest)

        # Copy session records if present.
        wire_src = File.join(session_dir, "wire.jsonl")
        File.copy(wire_src, File.join(bundle_dir, "wire.jsonl")) if File.exists?(wire_src)
        state_src = File.join(session_dir, "state.json")
        File.copy(state_src, File.join(bundle_dir, "state.json")) if File.exists?(state_src)

        # Copy the global log when present.
        global_log = File.join(@home, ".hcode", "hcode.log")
        if File.exists?(global_log)
          File.copy(global_log, File.join(bundle_dir, "hcode.log"))
        end

        out_path = File.join(tmp_dir, "hcode-debug-#{Time.utc.to_unix}.tar.gz")
        begin
          Process.run("tar", ["-czf", out_path, "-C", File.dirname(bundle_dir), File.basename(bundle_dir)],
                      output: Process::Redirect::Close, error: Process::Redirect::Close)
          out_path if File.exists?(out_path)
        rescue
          nil
        ensure
          FileUtils.rm_r(bundle_dir) rescue nil
        end
      end

      private def handle_slash_command(input : String) : Nil
        parsed = CommandRegistry.parse(input)
        unless parsed
          submit_message(input)
          return
        end

        cmd = parsed.not_nil!.command
        args = parsed.not_nil!.args

        case cmd
        when "/help"
          open_help_panel
        when "/exit", "/quit"
          @exit_confirm = true
          @dirty = true
          return
        when "/new"
          if @agent_busy
            @messages << Message.new("error", "Cannot start a new session while a turn is running. Wait or interrupt first.")
          else
            @on_new_session.try(&.call)
            @messages.clear
            @messages << Message.new("system", "New session started.")
          end
        when "/sessions", "/resume"
          if @agent_busy
            @messages << Message.new("error", "Cannot switch sessions while a turn is running.")
          else
            open_session_selector(:resume)
          end
        when "/restore"
          if @agent_busy
            @messages << Message.new("error", "Cannot restore a session while a turn is running.")
          else
            open_session_selector(:restore)
          end
        when "/fork"
          if @agent_busy
            @messages << Message.new("error", "Cannot fork while a turn is running. Wait or interrupt first.")
          elsif cb = @on_fork
            cb.call
            @messages << Message.new("system", "Session forked.")
          else
            @messages << Message.new("error", "Session fork is not wired up.")
          end
        when "/archive"
          if @agent_busy
            @messages << Message.new("error", "Cannot archive while a turn is running.")
          elsif cb = @on_archive
            cb.call
            @messages << Message.new("system", "Session archived. Use /restore to bring it back.")
          else
            @messages << Message.new("error", "Session archive is not wired up.")
          end
        when "/rename", "/title"
          if args.empty?
            @messages << Message.new("system", "Usage: /rename <new title>")
          elsif cb = @on_rename
            cb.call(args)
            @messages << Message.new("system", "Session title set to: #{args}")
          else
            @messages << Message.new("error", "Session rename is not wired up.")
          end
        when "/clear"
          if @agent_busy
            @messages << Message.new("error", "Cannot clear while a turn is running. Wait or interrupt first.")
          else
            @on_clear.try(&.call)
            @messages.clear
            @messages << Message.new("system", "Conversation cleared.")
          end
        when "/compact"
          if @agent_busy
            @messages << Message.new("error", "Cannot compact while a turn is running. Wait or interrupt first.")
          else
            @messages << Message.new("system", "Compacting context...")
            @is_compacting = true
            @status = "Compacting..."
            @spinner.start
            @dirty = true
            @on_compact.try(&.call)
          end
        when "/status"
          stats = String.build do |s|
            s << "Model: #{@model}\n"
            s << "Permission: #{@permission_mode}\n"
            if @max_context_tokens > 0
              s << "Context: #{build_context_status.sub(/^context: /, "")}\n"
            else
              s << "Context: #{@context_percent.round(1)}%\n"
            end
            s << "Messages: #{@messages.size}\n"
            s << "Queue: #{@queue.size}\n"
          end
          @messages << Message.new("system", stats.strip)
        when "/undo"
          if @agent_busy
            @messages << Message.new("error", "Cannot undo while a turn is running. Wait or interrupt first.")
          elsif args.strip.empty?
            open_undo_selector
          else
            count = args.strip.to_i? || 1
            @on_undo.try(&.call)
            @messages << Message.new("system", "Undid last #{count} turn(s).")
          end
        when "/queue"
          if args.strip == "clear"
            @queue.clear
            @messages << Message.new("system", "Queue cleared.")
          elsif @queue.empty?
            @messages << Message.new("system", "Queue is empty.")
          else
            preview = @queue.map_with_index { |qm, i| "  #{i + 1}. #{truncate_preview(qm.text)}" }.join("\n")
            @messages << Message.new("system", "Queue (#{@queue.size}):\n#{preview}\n— #{queue_hint}")
          end
        when "/yolo"
          @permission_mode = "yolo"
          @messages << Message.new("system", "Permission mode: yolo (auto-approve all)")
        when "/auto"
          @permission_mode = "auto"
          @messages << Message.new("system", "Permission mode: auto (safe operations)")
        when "/manual"
          @permission_mode = "manual"
          @messages << Message.new("system", "Permission mode: manual (approve each)")
        when "/model"
          open_model_selector
        when "/provider"
          open_provider_selector
        when "/export-md"
          path = args.empty? ? "session-#{Time.utc.to_unix}.md" : args
          @on_export.try(&.call(path))
          @messages << Message.new("system", "Exported to #{path}")
        when "/add-dir"
          if args.empty?
            @messages << Message.new("system", "Usage: /add-dir <path>")
          else
            @messages << Message.new("system", "Added directory: #{args}")
          end
        when "/theme"
          if args.empty?
            open_theme_selector
          elsif args == "dark"
            @theme = Theme.dark
            @messages << Message.new("system", "Theme: dark")
          elsif args == "light"
            @theme = Theme.light
            @messages << Message.new("system", "Theme: light")
          else
            @messages << Message.new("error", "Unknown theme: #{args}. Available: dark, light")
          end
        when "/version"
          version = Hcode::VERSION
          build = Hcode.build_date || "dev"
          @messages << Message.new("system", "hcode #{version} (#{build})\nCrystal #{Crystal::VERSION}")
        when "/usage"
          usage_stats = String.build do |s|
            s << "Provider: #{@provider_name}\n"
            s << "Model: #{@model}\n"
            if @max_context_tokens > 0
              used_pct = @context_percent.round(1)
              s << "Context: #{@context_tokens} / #{@max_context_tokens} tokens (#{used_pct}%)\n"
            else
              s << "Context: #{@context_percent.round(1)}%\n"
            end
            s << "Messages: #{@messages.size}\n"
            s << "Queue: #{@queue.size}\n"
          end
          @messages << Message.new("system", usage_stats.strip)
        when "/editor"
          handle_external_editor
        when "/copy"
          last_assistant = @messages.reverse.find { |m| m.role == "assistant" }
          if last_assistant
            copy_to_clipboard(last_assistant.content)
            @messages << Message.new("system", "Copied last assistant message to clipboard.")
          else
            @messages << Message.new("error", "No assistant message to copy.")
          end
        when "/permission"
          case args.strip.downcase
          when "manual", "auto", "yolo"
            apply_permission_mode(args.strip.downcase)
          when ""
            open_permission_selector
          else
            @messages << Message.new("error", "Unknown mode: #{args}. Available: manual, auto, yolo")
          end
        when "/effort"
          if args.empty?
            open_effort_selector
          elsif cb = @on_set_effort
            normalized = args.strip.downcase
            cb.call(normalized)
            @messages << Message.new("system", "Thinking effort set to: #{normalized}")
          else
            @messages << Message.new("system", "Thinking effort selection is not wired up.")
          end
        when "/plan"
          if @on_plan_mode.try(&.call(!@plan_mode))
            @plan_mode = !@plan_mode
            @messages << Message.new("system", "Plan mode: #{@plan_mode ? "on" : "off"}")
          else
            @messages << Message.new("error", "Plan mode is not wired up.")
          end
        when "/todos"
          todos = current_todos
          if todos.nil? || todos.empty?
            @messages << Message.new("system", "No todos.")
          elsif args.strip.downcase == "clear"
            @on_clear_todos.try(&.call)
            @messages << Message.new("system", "Todo list cleared (visible to the agent next step).")
          else
            body = todos.map_with_index do |(title, status), i|
              marker = case status
                       when "done"        then "✓"
                       when "in_progress" then "▶"
                       else                    "○"
                       end
              "  #{i + 1}. #{marker} #{title}"
            end.join("\n")
            @messages << Message.new("system", "Todos (#{todos.size}):\n#{body}")
          end
        when "/debug"
          if cb = @on_debug
            cb.call
          else
            @messages << Message.new("error", "/debug is not wired up.")
          end
        when "/feedback"
          if args.strip.empty?
            @messages << Message.new("system", "Usage: /feedback <message>")
          elsif cb = @on_feedback
            cb.call(args.strip)
            @messages << Message.new("system", "Feedback sent. Thank you!")
          else
            # Local fallback: stash the feedback so it can be retrieved later.
            feedback_path = File.join(@home, ".hcode", "feedback.log")
            Dir.mkdir_p(File.dirname(feedback_path)) rescue nil
            File.write(feedback_path, "[#{Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")}] #{args.strip}\n", mode: "a")
            @messages << Message.new("system", "Feedback saved to #{feedback_path}.")
          end
        when "/reload"
          if cb = @on_reload
            cb.call
            @messages << Message.new("system", "Config and session state reloaded.")
          else
            @messages << Message.new("error", "Reload is not wired up.")
          end
        when "/web"
          url = "https://www.kimi.com/code?session=#{URI.encode_path(@session_id)}"
          @messages << Message.new("system", "Open in Web UI: #{url}")
        when "/settings"
          settings = String.build do |s|
            s << "Provider: #{@provider_name}\n"
            s << "Model: #{@model}\n"
            s << "Permission: #{@permission_mode}\n"
            s << "Theme: #{@theme.name}\n"
            effort = @on_get_effort.try(&.call) || "off"
            s << "Thinking effort: #{effort}\n"
            s << "Home: #{@home}\n"
            s << "Work dir: #{@work_dir}\n"
            s << "Git branch: #{@git_branch.empty? ? "(none)" : @git_branch}\n"
          end
          @messages << Message.new("system", settings.strip)
        when "/init"
          # Mirrors TS `handleInitCommand` → `session.init()`: defer any
          # user messages typed during the run, then send the AGENTS.md
          # generation prompt as a regular turn. The agent walks the repo
          # (Bash, Read, Glob) and writes AGENTS.md to the project root.
          if @agent_busy
            @messages << Message.new("error", "Cannot /init while a turn is running. Wait or interrupt first.")
          else
            @defer_user_messages = true
            @messages << Message.new("system", "Analyzing codebase and generating AGENTS.md...")
            @dirty = true
            spawn do
              begin
                start_turn(INIT_PROMPT)
              ensure
                @defer_user_messages = false
              end
            end
          end
        when "/export-debug-zip"
          # Mirrors TS `handleExportDebugZipCommand`: bundle the session
          # records (wire.jsonl, state.json), a small manifest (version /
          # provider / model / timestamps), and the global log into a
          # tar.gz the user can share for debugging. Falls back to printing
          # the session dir path if tar is unavailable.
          path = export_debug_bundle
          if path
            @messages << Message.new("system", "Debug bundle exported to: #{path}")
          else
            @messages << Message.new("error", "Failed to export debug bundle (tar not available?).")
          end
        when "/experiments"
          # Mirrors TS `showExperimentsPanel`: enumerate experimental flags
          # and their current state. hcode has no registry yet — flags are
          # env-driven (HCODE_EXPERIMENTAL_<NAME>) plus the master switch
          # HCODE_EXPERIMENTAL_FLAG=1. Surface the env so the user knows
          # what is on.
          master = ENV["HCODE_EXPERIMENTAL_FLAG"]?
          env_flags = ENV.keys.select { |k|
            k.starts_with?("HCODE_EXPERIMENTAL_") && k != "HCODE_EXPERIMENTAL_FLAG"
          }.sort
          body = String.build do |s|
            s << "Master switch (HCODE_EXPERIMENTAL_FLAG): #{master || "off"}\n"
            if env_flags.empty?
              s << "No individual experimental flags set.\n"
            else
              s << "Active flags:\n"
              env_flags.each do |k|
                s << "  #{k} = #{ENV[k]}\n"
              end
            end
            s << "\nFlags are read at startup; restart hcode after changing them."
          end
          @messages << Message.new("system", body.strip)
        when "/mcp"
          # Mirrors TS `showMcpServers`. hcode.cr has no MCP client yet —
          # surface that clearly rather than silently no-op'ing.
          @messages << Message.new("system",
            "MCP servers: not supported in this build.\n" \
            "MCP client support is tracked as future work; use the TS version if you need it now.")
        when "/plugins"
          # Mirrors TS `handlePluginsCommand`. hcode.cr has no plugin runtime.
          @messages << Message.new("system",
            "Plugins: not supported in this build.\n" \
            "Plugin runtime is tracked as future work.")
        when "/login"
          # hcode has no in-process OAuth device-code flow (no src/auth/
          # yet). Surface the manual config options so the user can still
          # authenticate.
          cfg_path = File.join(@home, ".hcode", "config.toml")
          cred_path = File.join(@home, ".kimi-code", "credentials", "kimi-code.json")
          body = String.build do |s|
            s << "Authentication options:\n"
            s << "  1. API key in config.toml:\n"
            s << "       [provider.moonshot]\n"
            s << "       api_key = \"sk-...\"\n"
            s << "     Path: #{cfg_path}\n"
            s << "  2. Moonshot OAuth credentials (JSON file from kimi-code TS):\n"
            s << "       #{cred_path}\n"
            s << "  3. Environment variable:\n"
            s << "       HCODE_API_KEY=sk-...\n\n"
            s << "OAuth device-code login (/login interactive) is tracked as future work."
          end
          @messages << Message.new("system", body.strip)
        when "/logout"
          if cb = @on_logout
            cb.call
            @messages << Message.new("system", "Logged out. API key cleared from config.")
          else
            @messages << Message.new("error", "Logout is not wired up.")
          end
        when "/tasks", "/task"
          open_tasks_browser
        when "/memory"
          @messages << Message.new("system", ProfiledMemory.format_report)
        else
          @messages << Message.new("error", "Unknown command: #{cmd}. Type /help for available commands.")
        end

        @show_command_hints = false
        @dirty = true
      end

      private def open_tasks_browser : Nil
        unless cb = @on_fetch_tasks
          @messages << Message.new("error", "Tasks browser is not wired up (no task service).")
          return
        end

        on_select = ->(task_id : String) { nil }
        on_toggle = -> : Nil do
          @tasks_browser.filter = @tasks_browser.filter == TasksBrowser::Filter::Active ? TasksBrowser::Filter::All : TasksBrowser::Filter::Active
          @tasks_browser.refresh_tasks
          nil
        end
        on_refresh = -> : Nil do
          @tasks_browser.refresh_tasks
          @tasks_browser.flash_message = "Refreshed."
          nil
        end
        on_stop_confirmed = ->(task_id : String) do
          @on_stop_task.try(&.call(task_id))
          @tasks_browser.flash_message = "Stopping #{task_id}..."
          @tasks_browser.refresh_tasks
          nil
        end
        on_stop_ignored = ->(task_id : String) do
          @tasks_browser.flash_message = "#{task_id} is already finished."
          nil
        end
        on_open_output = ->(task_id : String) do
          @on_open_task_output.try(&.call(task_id))
          @tasks_browser.flash_message = "Opening output for #{task_id}..."
          nil
        end
        on_cancel = -> : Nil do
          @tasks_browser.hide
          @dirty = true
          nil
        end

        @tasks_browser.show(
          cb,
          on_select: on_select,
          on_toggle_filter: on_toggle,
          on_refresh: on_refresh,
          on_stop_confirmed: on_stop_confirmed,
          on_stop_ignored: on_stop_ignored,
          on_open_output: on_open_output,
          on_cancel: on_cancel,
          initial_filter: TasksBrowser::Filter::Active,
        )
        @input.drain_pending_enters
        @dirty = true
      end

      private def open_undo_selector : Nil
        unless cb = @on_fetch_undo_choices
          @on_undo.try(&.call)
          @messages << Message.new("system", "Undid last turn.")
          return
        end

        raw = cb.call
        if raw.nil? || raw.empty?
          @messages << Message.new("system", "No turns to undo.")
          return
        end

        choices = raw.map_with_index do |(count, input, label), i|
          UndoDialog::Choice.new("undo-#{i}", count, input, label)
        end

        on_select = ->(c : UndoDialog::Choice) do
          if cb2 = @on_undo_count
            cb2.call(c.count)
          else
            @on_undo.try(&.call)
          end
          @messages << Message.new("system", "Undid #{c.count} turn(s).")
          nil
        end

        @undo_dialog.show(choices, on_select)
        @input.drain_pending_enters
        @dirty = true
      end

      private def open_help_panel : Nil
        @help_panel.show
        # Discard a queued Enter that was batched with the /help submit,
        # otherwise it would immediately dismiss the panel on the next read_key.
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_help_key(key : KeyEvent) : Nil
        @help_panel.handle_input(key)
        @dirty = true
      end

      private def open_provider_selector : Nil
        items = LLM::KNOWN_PROVIDERS.map(&.name)
        @provider_list.show("Select provider", items)
        @provider_list.selected = items.index(@provider_name) || 0
        # Discard a queued Enter that was batched with the /provider submit,
        # otherwise it would close the selector on the very next read_key.
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_provider_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @provider_list.handle_input(key)
          @dirty = true
        when .enter?
          name = @provider_list.current || @provider_name
          @provider_list.hide
          @dirty = true
          if name == @provider_name
            @messages << Message.new("system", "Provider already set to #{name}.")
          elsif cb = @on_provider_change
            if cb.call(name)
              @provider_name = name
              @messages << Message.new("system", "Switched provider to #{name}.")
            end
          else
            @messages << Message.new("error", "Provider switching is not wired up.")
          end
        when .escape?
          @provider_list.hide
          @dirty = true
        end
      end

      PERMISSION_MODES = ["manual", "auto", "yolo"]
      EFFORT_LEVELS   = ["off", "low", "medium", "high"]
      THEMES          = ["dark", "light"]

      # Prompt sent by `/init` — mirrors TS `DEFAULT_INIT_PROMPT`
      # (`packages/agent-core/src/profile/default/init.md`).
      INIT_PROMPT = <<-TEXT
        You are a software engineering expert with many years of programming experience. Please explore the current project directory to understand the project's architecture and main details.

        Task requirements:
        1. Analyze the project structure and identify key configuration files (such as pyproject.toml, package.json, Cargo.toml, shard.yml, etc.).
        2. Understand the project's technology stack, build process and runtime architecture.
        3. Identify how the code is organized and main module divisions.
        4. Discover project-specific development conventions, testing strategies, and deployment processes.

        After the exploration, do a thorough summary of your findings and write it to the `AGENTS.md` file in the project root, replacing the file's previous content. If the file already exists, read it first and carry forward whatever is still accurate — the result should be one coherent, up-to-date file, not an append.

        For your information, `AGENTS.md` is a file intended to be read by AI coding agents. Expect the reader of this file to know nothing about the project.

        You should compose this file according to the actual project content. Do not make any assumptions or generalizations. Ensure the information is accurate and useful. You must use the natural language that is mainly used in the project's comments and documentation.

        Popular sections that people usually write in `AGENTS.md` are:

        - Project overview
        - Build and test commands
        - Code style guidelines
        - Testing instructions
        - Security considerations
      TEXT

      private def open_permission_selector : Nil
        @permission_list.show("Select permission mode", PERMISSION_MODES)
        @permission_list.selected = PERMISSION_MODES.index(@permission_mode) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_permission_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @permission_list.handle_input(key)
          @dirty = true
        when .enter?
          mode = @permission_list.current || @permission_mode
          @permission_list.hide
          @dirty = true
          apply_permission_mode(mode)
        when .escape?
          @permission_list.hide
          @dirty = true
        end
      end

      private def apply_permission_mode(mode : String) : Nil
        @permission_mode = mode
        @messages << Message.new("system", "Permission mode: #{mode}")
        @dirty = true
      end

      private def open_effort_selector : Nil
        current = @on_get_effort.try(&.call) || "off"
        @effort_list.show("Select thinking effort", EFFORT_LEVELS)
        @effort_list.selected = EFFORT_LEVELS.index(current) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_effort_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @effort_list.handle_input(key)
          @dirty = true
        when .enter?
          effort = @effort_list.current || "off"
          @effort_list.hide
          @dirty = true
          if cb = @on_set_effort
            normalized = effort == "off" ? nil : effort
            cb.call(effort)
            @messages << Message.new("system", "Thinking effort set to: #{effort}")
          else
            @messages << Message.new("system", "Thinking effort selection is not wired up.")
          end
        when .escape?
          @effort_list.hide
          @dirty = true
        end
      end

      private def open_theme_selector : Nil
        @theme_list.show("Select theme", THEMES)
        @theme_list.selected = THEMES.index(@theme.name) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_theme_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @theme_list.handle_input(key)
          @dirty = true
        when .enter?
          name = @theme_list.current || "dark"
          @theme_list.hide
          @dirty = true
          @theme = name == "light" ? Theme.light : Theme.dark
          @messages << Message.new("system", "Theme: #{name}")
        when .escape?
          @theme_list.hide
          @dirty = true
        end
      end

      private def open_session_selector(mode : Symbol) : Nil
        @session_picker_mode = mode
        include_archived = mode == :restore
        title = include_archived ? "Restore a session (archived)" : "Resume a session"

        entries = Session::Index.new(@home).list(include_archived: include_archived)
        if entries.empty?
          msg = include_archived ? "No archived sessions to restore." : "No sessions found."
          @messages << Message.new("system", msg)
          return
        end

        @session_entries = entries
        items = entries.map { |e| session_picker_label(e) }
        @session_list.show(title, items)
        @session_list.selected = 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def session_picker_label(entry : Session::SessionEntry) : String
        label = sanitize_picker_text(entry.label)
        preview_raw = entry.preview
        preview = preview_raw.empty? ? "" : " — #{sanitize_picker_text(preview_raw)}"
        time = entry.updated_at.to_s("%Y-%m-%d %H:%M")
        "#{label}#{preview}  (#{time})"
      end

      # Strip ANSI escapes, literal caret-escaped sequences (^[[A etc.), and
      # other control characters that corrupt line-oriented TUI rendering.
      private def sanitize_picker_text(text : String) : String
        cleaned = CharWidth.strip_ansi(text)
        # Remove literal caret-escaped ANSI sequences (e.g. "^[[A" from pasted
        # terminal output) that appear as visible garbage in the selector.
        cleaned = cleaned.gsub(/\^\[\[[0-9;?]*[A-Za-z]/, "")
        cleaned = cleaned.gsub(/[\x00-\x08\x0B-\x1F\x7F]/, "")
        # Collapse whitespace runs (including embedded newlines/tabs) to spaces.
        cleaned = cleaned.gsub(/\s+/, " ").strip
        cleaned
      end

      private def handle_session_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @session_list.handle_input(key)
          @dirty = true
        when .enter?
          idx = @session_list.selected
          entry = @session_entries[idx]?
          @session_list.hide
          @dirty = true
          unless entry
            @messages << Message.new("error", "No session selected.")
            return
          end
          case @session_picker_mode
          when :restore
            Session::Lifecycle.new(@home).restore(entry)
            @messages << Message.new("system", "Restored session: #{entry.label}")
          else
            if cb = @on_resume_session
              @messages << Message.new("system", "Resuming session: #{entry.label}")
              cb.call(entry.path)
            else
              @messages << Message.new("error", "Session resume is not wired up.")
            end
          end
        when .escape?
          @session_list.hide
          @dirty = true
        end
      end

      private def render_session_panel(cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{@session_list.title}#{ANSI.reset}"

        start, count = @session_list.visible_window
        if @session_list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = CharWidth.truncate_to_width(@session_list.items[i], cols - 4)
          if i == @session_list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{item}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{item}#{ANSI.reset}"
          end
        end
        if @session_list.scrolled_down?
          remaining = @session_list.items.size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def open_model_selector : Nil
        cb = @on_fetch_models
        if cb.nil?
          @messages << Message.new("error", "Model fetching is not wired up.")
          return
        end

        @status = "Fetching models..."
        @dirty = true

        spawn do
          begin
            models = cb.call
            if models.empty?
              @messages << Message.new("system", "No models available for current provider.")
            else
              @model_list.show("Select model (#{@provider_name})", models)
              @model_list.selected = models.index(@model) || 0
            end
          rescue ex
            @messages << Message.new("error", "Failed to fetch models: #{ex.message}")
          ensure
            @status = ""
            @dirty = true
          end
        end
      end

      private def handle_model_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @model_list.handle_input(key)
          @dirty = true
        when .enter?
          model = @model_list.current || @model
          @model_list.hide
          @dirty = true
          if model == @model
            @messages << Message.new("system", "Model already set to #{model}.")
          elsif cb = @on_model_change
            if cb.call(model)
              @model = model
              @messages << Message.new("system", "Switched model to #{model}.")
            end
          else
            @messages << Message.new("error", "Model switching is not wired up.")
          end
        when .escape?
          @model_list.hide
          @dirty = true
        end
      end

      def render : Nil
        cols = @terminal.cols
        rows = @terminal.rows

        new_lines, editor_content_line = build_rendered_lines(cols)

        output = IO::Memory.new
        output << "\e[?2026h" # Begin synchronized update

        size_changed = cols != @last_cols || rows != @last_rows
        content_shrunk = new_lines.size < @max_lines_rendered

        if @first_render || size_changed || content_shrunk
          full_render(output, new_lines, rows)
        else
          diff_render(output, new_lines, rows)
        end

        position_cursor(output, new_lines.size, editor_content_line)
        output << "\e[?2026l" # End synchronized update

        print output.to_s
        STDOUT.flush

        @previous_lines = new_lines
        @last_cols = cols
        @last_rows = rows
        @cursor_line = new_lines.size
      end

      def build_rendered_lines(cols : Int32) : {Array(String), Int32}
        new_lines = [] of String

        # Full-screen modal takeovers (tasks browser) replace the entire
        # layout — mirrors TS container-swap mount of TasksBrowserApp.
        if @tasks_browser.visible?
          @tasks_browser.rows = @terminal.rows
          return {@tasks_browser.render(cols), 0}
        end

        if @show_welcome
          new_lines.concat(render_welcome_box(cols))
          new_lines << ""
        end

        @messages.each do |msg|
          new_lines.concat(render_message(msg, cols))
        end

        unless @streaming_thinking.empty?
          new_lines.concat(render_live_thinking(cols))
        end

        unless @streaming_text.empty?
          new_lines.concat(render_message(Message.new("assistant", @streaming_text), cols))
        end

        if @spinner.active? && @streaming_thinking.empty?
          new_lines << String.build do |s|
            s << ANSI.color(@theme.colors.primary, nil)
            s << Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]
            s << ANSI.reset
            s << " "
            s << ANSI.color(@theme.colors.muted, nil)
            s << @status
            s << ANSI.reset
          end
        end

        if req = @approval_pending
          new_lines.concat(render_approval_panel(req, cols))
        end

        if @question_dialog.visible?
          new_lines.concat(@question_dialog.render(cols))
        end

        if @undo_dialog.visible?
          new_lines.concat(@undo_dialog.render(cols))
        end

        if @provider_list.visible?
          new_lines.concat(render_provider_panel(cols))
        end

        if @model_list.visible?
          new_lines.concat(render_model_panel(cols))
        end

        if @session_list.visible?
          new_lines.concat(render_session_panel(cols))
        end

        if @permission_list.visible?
          new_lines.concat(render_select_panel(@permission_list, cols))
        end

        if @effort_list.visible?
          new_lines.concat(render_select_panel(@effort_list, cols))
        end

        if @theme_list.visible?
          new_lines.concat(render_select_panel(@theme_list, cols))
        end

        if todos = current_todos
          new_lines.concat(render_todo_panel(todos, cols))
        end
        unless @queue.empty?
          new_lines.concat(render_queue_pane(cols))
        end
        editor_start = new_lines.size
        if @help_panel.visible?
          # Modal `/help` replaces the editor — mirrors JS `mountEditorReplacement`.
          # Skip command hints too: the editor (and its autocomplete) is hidden.
          new_lines.concat(@help_panel.render(cols))
        else
          new_lines.concat(render_editor_box(cols))

          if @show_command_hints && @command_hints.size > 0
            @command_hints.each_with_index do |hint, i|
              usage_part = hint.usage.empty? ? "" : " #{ANSI.color(@theme.colors.dim, nil)}#{hint.usage}#{ANSI.reset}"
              if i == @command_hint_selected
                new_lines << "#{ANSI.color(@theme.colors.primary, nil)}#{ANSI.bold}  → #{hint.name.ljust(14)} #{hint.description}#{usage_part}#{ANSI.reset}"
              else
                new_lines << "#{ANSI.color(@theme.colors.dim, nil)}    #{hint.name.ljust(14)} #{hint.description}#{usage_part}#{ANSI.reset}"
              end
            end
          end
        end

        new_lines << render_footer(cols)

        if @exit_confirm
          new_lines << "#{ANSI.color(@theme.colors.warning, nil)} Press #{@exit_key} to exit#{ANSI.reset}"
        end

        # Defensive barrier mirroring pi-tui `doRender`: truncate every line to
        # `cols` so no component with an off-by-one in width math can push the
        # right border past the terminal edge, then guarantee a trailing SGR
        # reset so an unclosed style can't leak into the next line.
        truncate_render_lines(new_lines, cols)
        apply_line_resets(new_lines)

        {new_lines, editor_start + 1}
      end

      # Truncate each rendered line to `cols` visible columns. Uses the ASCII
      # fast path and only falls back to the grapheme walk for non-ASCII lines,
      # matching pi-tui's per-row truncate in `doRender`.
      private def truncate_render_lines(lines : Array(String), cols : Int32) : Nil
        return if cols <= 0
        lines.map_with_index! do |line, _|
          w = CharWidth.ascii_visible_width(line, cols) || CharWidth.visible_width(line)
          w > cols ? CharWidth.slice_by_column(line, 0, cols, strict: true) : line
        end
      end

      # Ensure each line ends with an SGR reset so color can't leak into the
      # next rendered element. Counterpart of pi-tui's `applyLineResets`.
      private def apply_line_resets(lines : Array(String)) : Nil
        reset = ANSI.reset
        lines.map_with_index! do |line, _|
          line.ends_with?(reset) ? line : line + reset
        end
      end

      private def full_render(output : IO::Memory, new_lines : Array(String), rows : Int32) : Nil
        output << "\e[2J\e[H\e[3J"
        new_lines.each_with_index do |line, i|
          output << "\r\n" if i > 0
          output << line
          output << "\e[0m\e[K"
        end
        @hardware_cursor_row = {0, new_lines.size - 1}.max
        @max_lines_rendered = new_lines.size
        @previous_viewport_top = {0, {rows, new_lines.size}.max - rows}.max
        @first_render = false
      end

      private def diff_render(output : IO::Memory, new_lines : Array(String), rows : Int32) : Nil
        prev_size = @previous_lines.size
        new_size = new_lines.size

        # Defensive shrink guard: if the new content is shorter than what we
        # last committed to the screen, the diff path's tail-clearing only
        # runs for the trailing changed region and can leave phantom rows.
        # Bail to a full repaint so @max_lines_rendered is reset cleanly.
        if new_size < @max_lines_rendered
          full_render(output, new_lines, rows)
          return
        end

        first_changed = -1
        last_changed = -1

        max_lines = {prev_size, new_size}.max
        max_lines.times do |i|
          old_line = i < prev_size ? @previous_lines[i] : ""
          new_line = i < new_size ? new_lines[i] : ""
          if old_line != new_line
            first_changed = i if first_changed < 0
            last_changed = i
          end
        end

        if new_size > prev_size
          first_changed = prev_size if first_changed < 0
          last_changed = {last_changed, new_size - 1}.max
        end

        if first_changed < 0
          # No lines changed; keep the hardware cursor where position_cursor
          # left it, just update the viewport bookkeeping in case the terminal
          # dimensions changed.
          buffer_length = {rows, new_size}.max
          @previous_viewport_top = {0, buffer_length - rows}.max
          @max_lines_rendered = {@max_lines_rendered, new_size}.max
          return
        end

        if first_changed < @previous_viewport_top
          full_render(output, new_lines, rows)
          return
        end

        prev_viewport_top = @previous_viewport_top
        prev_viewport_bottom = prev_viewport_top + rows - 1

        if first_changed > prev_viewport_bottom
          current_screen_row = @hardware_cursor_row - prev_viewport_top
          move_to_bottom = rows - 1 - current_screen_row
          output << "\e[#{move_to_bottom}B" if move_to_bottom > 0
          scroll = first_changed - prev_viewport_bottom
          output << "\r\n" * scroll
          prev_viewport_top += scroll
          @hardware_cursor_row = first_changed
        end

        line_diff = first_changed - @hardware_cursor_row
        if line_diff > 0
          output << "\e[#{line_diff}B"
        elsif line_diff < 0
          output << "\e[#{-line_diff}A"
        end
        output << "\r"

        render_end = {last_changed, new_size - 1}.min
        (first_changed..render_end).each do |i|
          output << "\r\n" if i > first_changed
          output << "\e[2K"
          output << new_lines[i]
        end

        final_cursor_row = render_end

        if render_end < new_size - 1
          move_down = new_size - 1 - render_end
          output << "\e[#{move_down}B"
          final_cursor_row = new_size - 1
        end

        if new_size < prev_size
          extra = prev_size - new_size
          extra.times do
            output << "\r\n\e[2K"
          end
          output << "\e[#{extra}A" if extra > 0
        end

        @hardware_cursor_row = final_cursor_row
        buffer_length = {rows, new_size}.max
        @previous_viewport_top = {0, buffer_length - rows}.max
        @max_lines_rendered = {@max_lines_rendered, new_size}.max
      end

      private def position_cursor(output : IO::Memory, new_size : Int32, editor_content_line : Int32) : Nil
        if @exit_confirm
          output << "\r"
          return
        end

        # No editor is rendered while the help overlay is open — park the
        # hardware cursor on the panel's last line and leave it hidden. The
        # next non-help render restores normal positioning.
        if @help_panel.visible?
          output << ANSI.hide_cursor
          target_row = {new_size - 1, 0}.max
          row_delta = target_row - @hardware_cursor_row
          output << "\e[#{row_delta}B" if row_delta > 0
          output << "\e[#{-row_delta}A" if row_delta < 0
          output << "\r"
          @hardware_cursor_row = target_row
          return
        end

        output << ANSI.show_cursor

        return if new_size <= 0

        # Cursor row/col are resolved against the soft-wrapped editor layout by
        # `render_editor_box` (which may wrap one logical line across several
        # terminal rows). Falling back to the raw editor cursor would misplace
        # the hardware cursor whenever the active line wraps.
        target_row = {editor_content_line + @editor_cursor_visual_row, new_size - 1}.min
        row_delta = target_row - @hardware_cursor_row
        if row_delta > 0
          output << "\e[#{row_delta}B"
        elsif row_delta < 0
          output << "\e[#{-row_delta}A"
        end

        editor_text_col = 5 + @editor_cursor_visual_col
        output << "\r\e[#{editor_text_col}G"
        @hardware_cursor_row = target_row
      end

      def render_message(msg : Message, cols : Int32) : Array(String)
        lines = [] of String

        case msg.role
        when "user"
          bullet_w = CharWidth.visible_width(USER_BULLET)
          bullet = "#{ANSI.color(@theme.colors.user_msg, nil)}#{ANSI.bold}#{USER_BULLET}#{ANSI.reset}"
          indent = " " * bullet_w
          wrap_text(msg.content, cols - bullet_w).each_with_index do |l, i|
            prefix = i == 0 ? bullet : indent
            lines << "#{prefix}#{ANSI.color(@theme.colors.user_msg, nil)}#{ANSI.bold}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "assistant"
          unless msg.content.empty?
            bullet = "#{ANSI.color(@theme.colors.text, nil)}#{STATUS_BULLET}#{ANSI.reset}"
            md_lines = @markdown.render(msg.content, cols)
            md_lines.each_with_index do |l, i|
              if i == 0
                body = l.starts_with?("  ") ? l[2..] : l
                lines << "#{bullet}#{body}"
              else
                lines << l
              end
            end
            lines << ""
          end
        when "tool"
          if name = msg.tool_name
            if group = msg.read_group
              # Normal TUI never expands tool output; /debug mode shows full history.
              lines.concat(render_read_group(group, name, false, cols))
            else
              has_result = !msg.tool_result.nil?
              lines << tool_header(name, msg.tool_args, msg.tool_result, has_result, msg.is_error)
              if args = msg.tool_args
                # The header already shows the key argument for most tools;
                # keep the body preview only when there is no header argument
                # (e.g. Bash still shows the command under the label header).
                key_arg = extract_key_argument(name, args)
                if name == "Bash" || key_arg.nil?
                  preview = tool_preview(name, args)
                  preview.each { |l| lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{l}#{ANSI.reset}" }
                end

                if name == "Edit"
                  render_edit_diff(msg.tool_display, args).each { |l| lines << l }
                end
              end
              if result = msg.tool_result
                # tool_result is already a short preview; full output is in JSONL.
                result.each_line do |l|
                  lines << "#{ANSI.color(@theme.colors.tool_result, nil)}  #{l}#{ANSI.reset}"
                end
              end
              # --ram: dim+italic line right under the result preview, so the
              # RSS progression stays visually attached to the tool that
              # caused it instead of floating off as a separate info block.
              if ram = msg.ram_line
                lines << "#{ANSI.color(@theme.colors.dim, nil)}#{ANSI.italic}  #{ram}#{ANSI.reset}"
              end
              lines << ""
            end
          end
        when "error"
          # Split by `\n` so each rendered line maps to one `lines[]` entry —
          # the diff-renderer invariant (1 entry == 1 terminal row) must hold.
          msg.content.split('\n').each do |l|
            lines << "#{ANSI.color(@theme.colors.error, nil)}Error: #{l}#{ANSI.reset}"
          end
          lines << ""
        when "status"
          msg.content.split('\n').each do |l|
            lines << "  #{ANSI.color(@theme.colors.error, nil)}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "system"
          msg.content.split('\n').each do |l|
            lines << "#{ANSI.color(@theme.colors.dim, nil)}#{ANSI.italic}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "thinking"
          lines.concat(render_thinking_block(msg.content, msg.expanded?, cols))
        when "step_summary"
          lines.concat(render_step_summary(msg))
        when "plan_box"
          lines.concat(render_plan_box(msg, cols))
        when "compaction"
          lines.concat(render_compaction_block(msg, cols))
        end

        lines
      end

      private def render_live_thinking(cols : Int32) : Array(String)
        lines = [] of String
        dc = ANSI.color(@theme.colors.dim, nil)
        pc = ANSI.color(@theme.colors.primary, nil)
        mc = ANSI.color(@theme.colors.muted, nil)
        r = ANSI.reset

        lines << ""

        content_lines = wrap_thinking(@streaming_thinking, cols - THINKING_INDENT.size)
        if content_lines.size > THINKING_PREVIEW_LINES
          preview_lines = content_lines[-THINKING_PREVIEW_LINES..]
        else
          preview_lines = content_lines
        end

        lines << String.build do |s|
          s << pc
          s << Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]
          s << r
          s << " "
          s << mc
          s << "thinking..."
          s << r
        end

        preview_lines.each do |cl|
          lines << "#{THINKING_INDENT}#{dc}#{ANSI.italic}#{cl}#{r}"
        end

        lines
      end

      # ExitPlanMode result strings carry an approved / auto-approved / rejected
      # plan body prefixed with a known marker. Mirrors TS `tool-call.ts`:
      #   - "## Approved Plan:"                          → approved
      #   - "## Plan (auto-approved, not user-reviewed):" → auto_approved
      #   - "Plan rejected by user." / "User rejected"   → rejected
      # When the marker is found, push a "plan_box" message into the transcript
      # so `render_message` can draw a bordered box for the plan body. Mirrors
      # `buildPlanPreview` in `tool-call.ts` which lifts the plan out of the
      # result into a `PlanBoxComponent`.
      private def inject_plan_if_any(tool_output : String) : Nil
        return unless tool_output.includes?("Plan")
        plan_body, kind = extract_plan_body(tool_output)
        return if plan_body.empty?
        msg = Message.new("plan_box", plan_body)
        msg.plan_kind = kind
        msg.plan_path = extract_plan_path(tool_output)
        @messages << msg
      end

      # Returns the plan body (stripped) and its kind. Body is empty when the
      # output is not a recognised ExitPlanMode outcome.
      private def extract_plan_body(output : String) : {String, String}
        auto_marker = "## Plan (auto-approved, not user-reviewed):"
        approved_marker = "## Approved Plan:"
        if idx = output.index(auto_marker)
          body = output[(idx + auto_marker.size)..].strip
          return {body, "auto_approved"}
        end
        if idx = output.index(approved_marker)
          body = output[(idx + approved_marker.size)..].strip
          return {body, "approved"}
        end
        return {"", "approved"} if output.includes?("Plan rejected by user.")
        {"", ""}
      end

      # Extract the "Plan saved to: <path>" line if present, mirroring the
      # TS `PLAN_SAVED_TO_RE` regex.
      private def extract_plan_path(output : String) : String?
        if m = output.match(/\nPlan saved to: ([^\n]+)\n/)
          p = m[1]?.try(&.strip)
          p unless p.try(&.empty?)
        end
      end

      # Bordered box around a markdown-rendered plan, mirroring TS
      # `PlanBoxComponent`: "  ┌── plan: name ──┐", "  │ body │", "  └──┘".
      # The title embeds the plan filename (when known) and a Rejected
      # badge in error colour for rejected plans.
      # Compaction block — port of TS `CompactionComponent`. While running,
      # the bullet blinks (white ↔ blank); once done the bullet turns solid
      # green with "(N → M tokens)"; cancelled turns it warning-yellow. The
      # summary can be toggled with Ctrl-O via the generic `expanded` flag.
      private def render_compaction_block(msg : Message, cols : Int32) : Array(String)
        lines = [] of String
        success = @theme.colors.success
        warning = @theme.colors.warning
        primary = @theme.colors.primary
        dim = @theme.colors.dim
        text_c = @theme.colors.text

        case msg.compaction_state
        when "done"
          bullet = "#{ANSI.color(success, nil)}#{STATUS_BULLET}#{ANSI.reset}"
          label = "#{ANSI.color(success, nil)}#{ANSI.bold}Compaction complete#{ANSI.reset}"
          detail = ""
          if (tb = msg.tokens_before) && (ta = msg.tokens_after)
            detail = " #{ANSI.color(dim, nil)}(#{tb} → #{ta} tokens)#{ANSI.reset}"
          end
          hint = ""
          unless msg.summary.empty?
            hint = " #{ANSI.color(dim, nil)}(Ctrl-O to #{msg.expanded? ? "hide" : "show"} compaction summary)#{ANSI.reset}"
          end
          lines << ""
          lines << "#{bullet}#{label}#{detail}#{hint}"
          if msg.expanded? && !msg.summary.empty?
            msg.summary.split('\n').each do |sl|
              lines << "#{ANSI.color(dim, nil)}  #{sl}#{ANSI.reset}"
            end
          end
        when "cancelled"
          bullet = "#{ANSI.color(warning, nil)}#{STATUS_BULLET}#{ANSI.reset}"
          label = "#{ANSI.color(warning, nil)}#{ANSI.bold}Compaction cancelled#{ANSI.reset}"
          lines << ""
          lines << "#{bullet}#{label}"
        else
          # Running: blink the bullet every 500ms — same cadence as TS.
          blink_on = ((Time.utc.to_unix_ms // 500) % 2) == 0
          bullet = blink_on ? "#{ANSI.color(text_c, nil)}#{STATUS_BULLET}#{ANSI.reset}" : "  "
          label = "#{ANSI.color(primary, nil)}#{ANSI.bold}Compacting context...#{ANSI.reset}"
          tip = ""
          unless msg.tip.empty?
            tip = " #{ANSI.color(dim, nil)}· Tip: #{msg.tip}#{ANSI.reset}"
          end
          lines << ""
          lines << "#{bullet}#{label}#{tip}"
        end
        lines
      end

      def render_plan_box(msg : Message, cols : Int32) : Array(String)
        lines = [] of String
        border = ANSI.color(@theme.colors.success, nil)
        border = ANSI.color(@theme.colors.error, nil) if msg.plan_kind == "rejected"

        left_margin = 2
        side_padding = 1
        safe_cols = cols < 6 ? 6 : cols
        horz_len = {2, safe_cols - left_margin - 2}.max
        content_width = {1, horz_len - 2 * side_padding}.max

        # Title row: " plan: <basename>" or " plan"; Rejected badge appended.
        path_part = msg.plan_path.try { |p| ": #{File.basename(p)}" } || ""
        status_suffix = msg.plan_kind == "rejected" ? " · #{ANSI.color(@theme.colors.error, nil)}Rejected#{ANSI.reset}" : ""
        title = " plan#{path_part}#{status_suffix} "
        title_display = title_visible(title)
        if visible_len(title_display) > horz_len - 1
          title = " plan "
          title_display = title_visible(title)
        end
        trailing = (horz_len - visible_len(title_display)).clamp(0..)
        top = "#{" " * left_margin}#{border}┌#{title}#{border}#{"─" * trailing}┐#{ANSI.reset}"

        lines << ""
        lines << top

        body_lines = render_plan_body_lines(msg.content, content_width)
        body_lines.each do |raw|
          # Clamp to content_width so a long line (e.g. code inside the plan)
          # can't overflow the box and push the right border onto the next
          # terminal row — which reads as a stray blank line.
          vw = visible_len(raw)
          raw = CharWidth.slice_by_column(raw, 0, content_width, strict: true) if vw > content_width
          pad = (content_width - visible_len(raw)).clamp(0..)
          lines << "#{" " * left_margin}#{border}│#{ANSI.reset} #{raw}#{" " * pad} #{border}│#{ANSI.reset}"
        end

        lines << "#{" " * left_margin}#{border}└#{"─" * horz_len}┘#{ANSI.reset}"
        lines
      end

      # `title` is a String that may contain ANSI escapes (for the Rejected
      # badge); this returns only the visible-char count for box math.
      private def title_visible(title : String) : String
        title
      end

      # Render the plan body via the markdown renderer (already width-aware),
      # falling back to simple wrapping if markdown returns nothing.
      private def render_plan_body_lines(body : String, width : Int32) : Array(String)
        rendered = @markdown.render(body, width)
        rendered.empty? ? wrap_thinking(body, width) : rendered
      end

      private def render_thinking_block(content : String, expanded : Bool, cols : Int32) : Array(String)
        lines = [] of String
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset
        indent = THINKING_INDENT

        content_lines = wrap_thinking(content, cols - indent.size)

        lines << ""
        content_lines.each_with_index do |cl, i|
          prefix = i == 0 ? "#{dc}#{STATUS_BULLET}" : indent
          lines << "#{prefix}#{dc}#{ANSI.italic}#{cl}#{r}"
        end

        if !expanded && content_lines.size > THINKING_PREVIEW_LINES
          shown = lines[0..THINKING_PREVIEW_LINES]
          remaining = content_lines.size - THINKING_PREVIEW_LINES
          hint = "... (#{remaining} more lines, ctrl+o to expand)"
          shown << "#{indent}#{dc}#{hint}#{r}"
          lines = shown
        end

        lines
      end

      private def wrap_thinking(text : String, max_width : Int32) : Array(String)
        return [""] if text.empty?
        max_width = 1 if max_width < 1

        text.split('\n').flat_map do |line|
          line_w = CharWidth.visible_width(line)
          if line_w <= max_width
            [line]
          else
            words = line.split(' ')
            result = [] of String
            current = String::Builder.new
            current_w = 0

            words.each do |word|
              w = CharWidth.visible_width(word)
              if w > max_width
                if current_w > 0
                  result << current.to_s
                  current = String::Builder.new
                  current_w = 0
                end
                CharWidth.slice_into_width_chunks(word, max_width).each do |chunk|
                  result << chunk
                end
                next
              end

              sep = current_w > 0 ? 1 : 0
              if current_w + sep + w > max_width && current_w > 0
                result << current.to_s
                current = String::Builder.new
                current_w = 0
              end
              current << ' ' if current_w > 0
              current << word
              current_w += (current_w > 0 ? 1 : 0) + w
            end
            result << current.to_s if current_w > 0
            result
          end
        end.to_a
      end

      private def render_read_group(group : Array(ReadGroupEntry), name : String,
                                    expanded : Bool, cols : Int32) : Array(String)
        lines = [] of String
        total = group.size
        pending = group.count { |e| e.tool_result.nil? }
        failed = group.count { |e| e.is_error }
        done_lines = group.sum { |e| count_non_empty_lines(e.tool_result) }

        header = String.build do |s|
          s << ANSI.color(@theme.colors.tool_header, nil)
          s << ANSI.bold
          s << "▶ "
          if pending > 0
            s << "Reading #{total} files…"
          elsif failed == total
            s << "Read #{total} files · failed"
          else
            s << "Read #{total} files"
            s << " · #{done_lines} #{done_lines == 1 ? "line" : "lines"}"
            s << " · #{failed} failed" if failed > 0
          end
          s << ANSI.reset
        end
        lines << header

        visible_entries = group.select { |e| read_group_file_path(e.tool_args) }
        visible_entries.each_with_index do |entry, idx|
          is_last = idx == visible_entries.size - 1
          branch = is_last ? "└─" : "├─"
          path = read_group_file_path(entry.tool_args) || "?"
          tail = if entry.tool_result.nil?
                   " · reading…"
                 elsif entry.is_error
                   " · failed"
                 else
                   line_count = count_non_empty_lines(entry.tool_result)
                   " · #{line_count} #{line_count == 1 ? "line" : "lines"}"
                 end
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{branch} #{path}#{tail}#{ANSI.reset}"
        end

        if expanded
          group.each do |entry|
            next unless result = entry.tool_result
            result_lines = result.split('\n')
            max_lines = 200
            shown = result_lines.first(max_lines)
            shown.each do |l|
              lines << "#{ANSI.color(@theme.colors.tool_result, nil)}    #{l}#{ANSI.reset}"
            end
            if result_lines.size > max_lines
              lines << "#{ANSI.color(@theme.colors.dim, nil)}    ... (#{result_lines.size - max_lines} more)#{ANSI.reset}"
            end
          end
        end

        lines << ""
        lines
      end

      private def count_non_empty_lines(text : String?) : Int32
        return 0 if text.nil? || text.empty?
        text.split('\n').count { |line| !line.empty? }
      end

      private def read_group_file_path(args : String) : String?
        parsed = JSON.parse(args)
        path = parsed["filePath"]?.try(&.to_s) || parsed["path"]?.try(&.to_s)
        return nil if path.nil? || path.empty?
        path
      rescue
        nil
      end

      private def render_editor(cols : Int32) : Array(String)
        text = @editor.text
        if text.empty?
          return [""]
        end
        text.split('\n')
      end

      def render_welcome_box(cols : Int32) : Array(String)
        # Clamp to the logo width so the ASCII art (14 cols wide) can't push
        # the right border off-screen on very narrow terminals.
        box_w = {cols, 14}.max
        inner_w = box_w - 4

        logo_lines = [
          "    █   █     ",
          "  █████████   ",
          "  ██🔴█🔴██   ",
          "█████████████ ",
          "██▙▄▄▄▄▄▄▄▟██ ",
        ]

        lines = [] of String

        bc = ANSI.color(@theme.colors.border, nil)
        gc = ANSI.color(@theme.colors.logo, nil)
        rc = ANSI.color(@theme.colors.error, nil)
        mc = ANSI.color(@theme.colors.muted, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        r = ANSI.reset

        lines << "#{bc}╭#{"─" * (box_w - 2)}╮#{r}"

        # Optional side text + color matched to each logo line by index.
        # Logo lines beyond this list render on their own (logo only), so
        # adding rows to `logo_lines` is automatically reflected in the box.
        side_texts = [
          {"#{ANSI.bold}Welcome to HCode!#{r}", tc},
          {"Send /help for help information.", mc},
          {"", tc},
        ] of Tuple(String, String)

        logo_lines.each_with_index do |logo, i|
          text = ""
          color = tc
          if entry = side_texts[i]?
            text, color = entry
          end
          content_w = visible_len(text)
          used = 2 + visible_len(logo) + 2 + content_w
          pad = inner_w + 2 - used
          pad = 1 if pad < 1
          lines << "#{bc}│#{r}  #{colorize_logo(logo, gc, rc, r)}  #{color}#{text}#{" " * pad}#{bc}│#{r}"
        end

        lines << "#{bc}│#{r}#{" " * (box_w - 2)}#{bc}│#{r}"

        info = [
          {"Directory", @work_dir},
          {"Session", @session_id.empty? ? "new" : @session_id},
          {"Model", @model},
          {"Version", Hcode::VERSION},
        ]

        info.each do |label, value|
          content = "  #{mc}#{label}:#{r} #{tc}#{value}#{r}"
          pad = box_w - 2 - visible_len(content)
          pad = 1 if pad < 1
          lines << "#{bc}│#{r}#{content}#{" " * pad}#{bc}│#{r}"
        end

        lines << "#{bc}╰#{"─" * (box_w - 2)}╯#{r}"
        lines
      end

      # Render a logo line with two-tone coloring: the body uses `gray`, while
      # the 🔴 eye markers use `red`. Splitting on the eye marker (kept via the
      # capture group) lets us recolor each segment independently, so the eyes
      # stay red regardless of how the terminal applies ANSI fg to emoji.
      private def colorize_logo(logo : String, gray : String, red : String, r : String) : String
        return "#{gray}#{logo}#{r}" unless logo.includes?('🔴')
        String.build do |io|
          logo.split(/(🔴)/).each do |seg|
            if seg == "🔴"
              io << red << seg << r
            else
              io << gray << seg << r
            end
          end
        end
      end

      private def render_editor_box(cols : Int32) : Array(String)
        box_w = cols
        bc = ANSI.color(@theme.colors.border, nil)
        pc = ANSI.color(@theme.colors.primary, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset

        dash = "─" * {0, box_w - 2}.max
        lines = [] of String
        lines << "#{bc}╭#{dash}╮#{r}"

        if @editor.empty?
          # No content: park the cursor on the single placeholder row.
          prompt = "#{pc}#{ANSI.bold}>#{r} "
          body = "#{dc}Send a message...#{r}"
          lines << build_editor_row(box_w, bc, r, prompt, body)
          @editor_cursor_visual_row = 0
          @editor_cursor_visual_col = 0
        else
          cursor_row, cursor_col = @editor.cursor_position
          editor_lines = @editor.text.split('\n')

          # Inner content width: left border(1) + prompt(3) + content + right
          # border(1) = box_w ⇒ content = box_w - 5. Each rendered row is then
          # padded to exactly box_w so the right `│` lines up with the corners.
          inner_w = box_w - 5
          inner_w = 1 if inner_w < 1
          # Wrap one column narrower than the content area so the end-of-line
          # cursor (a highlighted trailing space) always fits without pushing
          # the right border past the box edge. Mirrors pi-tui's
          # `layoutWidth = contentWidth - 1`.
          wrap_w = inner_w - 1
          wrap_w = 1 if wrap_w < 1

          visual_row = 0
          found_cursor = false
          editor_lines.each_with_index do |eline, i|
            is_cursor_line = (i == cursor_row)
            chunks = wrap_editor_line(eline, wrap_w)
            chunks.each_with_index do |(chunk_text, chunk_start, chunk_end), ci|
              first = (i == 0 && ci == 0)
              prompt = first ? "#{pc}#{ANSI.bold}>#{r} " : "  "

              # Mirror pi-tui's layoutText cursor resolution: the cursor lives
              # in the chunk whose [start, end) covers cursor_col, except for
              # the final chunk which also owns the line-end position (>=).
              has_cursor = false
              local = 0
              if is_cursor_line
                is_last_chunk = (ci == chunks.size - 1)
                if is_last_chunk
                  has_cursor = cursor_col >= chunk_start
                else
                  has_cursor = cursor_col >= chunk_start && cursor_col < chunk_end
                end
                local = ({cursor_col - chunk_start, 0}.max)
                local = {local, chunk_text.size}.min if has_cursor
              end

              if has_cursor
                before = chunk_text[0...local]? || ""
                char_at = chunk_text[local]? || " "
                after = chunk_text[(local + 1)..]? || ""
                body = "#{tc}#{before}#{r}#{ANSI.color(nil, @theme.colors.primary)}#{char_at}#{r}#{tc}#{after}#{r}"
                @editor_cursor_visual_col = visible_len(before)
                found_cursor = true
              else
                body = "#{tc}#{chunk_text}#{r}"
              end

              lines << build_editor_row(box_w, bc, r, prompt, body)
              visual_row += 1 unless found_cursor
            end
          end

          @editor_cursor_visual_row = found_cursor ? visual_row : 0
        end

        lines << "#{bc}╰#{dash}╯#{r}"
        lines
      end

      # Build one editor content row padded to exactly `box_w` columns:
      # `│ <prompt><body>    │`. ANSI escapes are zero-width, so padding is
      # computed from visible widths, keeping the right border aligned with
      # the box corners even when `body` carries cursor/colour SGR codes.
      private def build_editor_row(box_w : Int32, bc : String, r : String, prompt : String, body : String) : String
        left = "#{bc}│#{r} #{prompt}"
        right = "#{bc}│#{r}"
        pad = box_w - visible_len(left) - visible_len(body) - visible_len(right)
        pad = 0 if pad < 0
        "#{left}#{body}#{" " * pad}#{right}"
      end

      # Soft-wrap one logical editor line into display chunks that each fit
      # `max_w` visible columns. Returns `{text, start_index, end_index}` per
      # chunk, where the indices are codepoint offsets into `line` (matching
      # the editor's codepoint-based cursor). Mirrors pi-tui's `wordWrapLine`:
      # word-boundary wrapping (break after whitespace) with a force-break
      # fallback for tokens longer than `max_w`, and CJK-aware break points.
      # Keeping grapheme clusters (base + combining marks, ZWJ emoji) intact
      # relies on `CharWidth.zero_width?` / `cjk_break?`.
      def wrap_editor_line(line : String, max_w : Int32) : Array({String, Int32, Int32})
        return [{"", 0_i32, 0_i32}] if line.empty? || max_w <= 0
        cps = line.codepoints.map(&.to_u32)
        n = cps.size

        # Pre-split into grapheme clusters with their start index, visible
        # width, whitespace flag, and base codepoint (for CJK break detection).
        clusters = [] of Tuple(Int32, Int32, Bool, UInt32)
        i = 0
        while i < n
          base = i
          k = i + 1
          while k < n
            cpk = cps[k]
            if CharWidth.zero_width?(cpk)
              k += 1
            elsif cps[k - 1] == 0x200D_u32 # ZWJ keeps the joined emoji in-cluster
              k += 1
            else
              break
            end
          end
          text = cps_to_string(cps, base, k)
          clusters << {base.to_i32, CharWidth.visible_width(text), text == " " || text == "\t", cps[base]}
          i = k
        end

        chunks = [] of {String, Int32, Int32}
        current_w = 0
        chunk_start = 0
        # Wrap opportunity: codepoint index where a break is allowed, plus the
        # visible width consumed up to that point (exclusive).
        wrap_idx = -1
        wrap_w = 0

        clusters.each_with_index do |(idx, w, is_space, base_cp), ci|
          if current_w + w > max_w
            # Single-grapheme guard (mirrors pi-tui editor.ts:172-181): if the
            # overflow is caused by an indivisible cluster wider than `max_w`
            # sitting at the start of the chunk, don't force-break — there's
            # nothing to split, so let the cluster occupy the line as-is.
            if chunk_start == idx && w > max_w
              # Skip break logic; the cluster is added below.
            elsif wrap_idx >= 0 && current_w - wrap_w + w <= max_w
              # Backtrack to the last word boundary — the remaining tail plus
              # this cluster still fits within max_w.
              chunks << {cps_to_string(cps, chunk_start, wrap_idx), chunk_start, wrap_idx}
              chunk_start = wrap_idx
              current_w -= wrap_w
            elsif chunk_start < idx
              # No viable word boundary (or backtracking wouldn't help): force
              # a break at the current cluster boundary.
              chunks << {cps_to_string(cps, chunk_start, idx), chunk_start, idx}
              chunk_start = idx
              current_w = 0
            end
            wrap_idx = -1
            wrap_w = 0
          end

          current_w += w

          if nxt = clusters[ci + 1]?
            _, _, next_space, next_cp = nxt
            if is_space && !next_space
              # Word boundary: whitespace immediately before non-whitespace.
              wrap_idx = idx + 1
              wrap_w = current_w
            elsif !is_space && !next_space && (CharWidth.cjk_break?(base_cp) || CharWidth.cjk_break?(next_cp))
              # CJK allows line breaks between any two adjacent characters.
              wrap_idx = idx + 1
              wrap_w = current_w
            end
          end
        end

        # Flush the trailing chunk (or the whole line when it never overflowed).
        if chunk_start < n || chunks.empty?
          chunks << {cps_to_string(cps, chunk_start, n), chunk_start, n}
        end
        chunks
      end

      private def cps_to_string(cps : Array(UInt32), start_idx : Int32, end_idx : Int32) : String
        return "" if start_idx >= end_idx
        String.build do |io|
          (start_idx...end_idx).each { |k| io << cps[k].chr }
        end
      end

      # Footer context readout. Mirrors the TS TUI's `formatContextStatus`:
      # when both the token count and the window size are known, render
      # `context: NN% (Xk/Yk)`; otherwise fall back to the precomputed
      # percent. The percent is recomputed from the raw counts so it does
      # not lag a step behind `@context_percent`.
      private def build_context_status : String
        if @max_context_tokens > 0 && @context_tokens > 0
          pct = (@context_tokens.to_f64 / @max_context_tokens * 100).ceil.to_i
          pct = 100 if pct > 100
          "context: #{pct}% (#{LLM::TokenCounter.format_count(@context_tokens)}/#{LLM::TokenCounter.format_count(@max_context_tokens)})"
        else
          "context: #{@context_percent.round(0).to_i}%"
        end
      end

      # Returns the current TodoList items via the `on_fetch_todos` callback
      # (wired in `hcode.cr` to `Tools::TodoList#todos`). Returns nil if the
      # tool isn't registered or no todos exist, so the panel is hidden.
      private def current_todos : Array({String, String})?
        return nil unless cb = @on_fetch_todos
        cb.call
      end

      # Todo panel: mirrors TS `components/chrome/todo-panel.ts`. Shows the
      # agent's structured TODO list (title + status) above the editor so
      # the user sees progress without scrolling through the transcript.
      private def render_todo_panel(todos : Array({String, String}), cols : Int32) : Array(String)
        lines = [] of String
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        success = @theme.colors.success
        warning = @theme.colors.warning

        pending = todos.count { |(_, s)| s != "done" }
        done = todos.size - pending
        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold}  Todos (#{done}/#{todos.size})#{ANSI.reset}"
        todos.each do |(title, status)|
          marker, color = case status
                          when "done"        then {"✓", success}
                          when "in_progress" then {"▶", warning}
                          else                    {"○", dim}
                          end
          lines << "#{ANSI.color(color, nil)}  #{marker} #{title}#{ANSI.reset}"
        end
        lines << "" if pending > 0
        lines
      end

      # Queue pane: lists messages typed while the agent was busy, plus a
      # context-sensitive hint. Mirrors TS `components/panes/queue-pane.ts`.
      # Shown only when `@queue` is non-empty.
      private def render_queue_pane(cols : Int32) : Array(String)
        lines = [] of String
        accent = @theme.colors.primary
        dim = @theme.colors.dim

        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold}  Queued (#{@queue.size})#{ANSI.reset} " \
                 "#{ANSI.color(dim, nil)}#{queue_hint}#{ANSI.reset}"
        @queue.each_with_index do |qm, i|
          preview = truncate_preview(qm.text)
          prefix = i == 0 ? "  ▶ " : "    "
          lines << "#{ANSI.color(dim, nil)}#{prefix}#{preview}#{ANSI.reset}"
        end
        lines
      end

      private def render_footer(cols : Int32) : String
        parts = [
          @provider_name,
          @permission_mode,
          @model,
        ]
        unless @git_branch.empty?
          parts << @git_branch
        end
        ctx_str = build_context_status

        left = parts.join("  ")
        # Right side: context usage + a rotating tip when idle, or just
        # context when the agent is busy (the status line owns the message
        # in that case). Mirrors TS footer tips rotation.
        tip = @agent_busy ? "" : "  " + current_tip
        right = ctx_str + tip

        gap = cols - visible_len(left) - visible_len(right)
        gap = 1 if gap < 1

        "#{ANSI.color(@theme.colors.dim, nil)}#{left}#{" " * gap}#{right}#{ANSI.reset}"
      end

      # Rotating keyboard / workflow hint shown in the footer when idle.
      # Picked by wall-clock seconds so it cycles without per-render state.
      TIPS = [
        "Ctrl+S steer · Ctrl+G editor",
        "↑↓ scroll · /debug for full output",
        "Enter queues while agent runs",
        "/help for all commands",
        "/usage for tokens · /queue clear",
        "Ctrl+C twice to exit",
      ]

      private def current_tip : String
        TIPS[(Time.utc.to_unix // 5) % TIPS.size]
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
        merge_turn_steps
      end

      private def visible_len(s : String) : Int32
        CharWidth.visible_width(s)
      end

      # Collapse older intermediate thinking/tool blocks within the current turn
      # into a single muted summary line, keeping the most recent N steps visible.
      # Mirrors the TypeScript TUI's `mergeCurrentTurnSteps`.
      private def merge_turn_steps : Nil
        merge_within_current_turn
        merge_old_turns
      end

      private def merge_within_current_turn : Nil
        keep = @keep_recent_steps
        return if keep <= 0

        # Find the start of the current turn (the most recent user message).
        turn_start = -1
        i = @messages.size - 1
        while i >= 0
          if @messages[i].role == "user"
            turn_start = i
            break
          end
          i -= 1
        end
        return if turn_start < 0

        step_indices = [] of Int32
        summary_idx = -1

        (turn_start + 1...@messages.size).each do |idx|
          case @messages[idx].role
          when "thinking", "tool"
            step_indices << idx
          when "step_summary"
            summary_idx = idx
          end
        end

        total = step_indices.size
        return if total <= keep

        merge_count = total - keep
        to_merge = step_indices.first(merge_count)

        thinking = 0
        tool = 0
        to_merge.each do |idx|
          case @messages[idx].role
          when "thinking" then thinking += 1
          when "tool"     then tool += 1
          end
        end

        # Delete from the end toward the start so indices remain valid.
        to_merge.reverse.each { |idx| @messages.delete_at(idx) }

        if summary_idx >= 0
          # Existing summary is always right after the user message, before the
          # blocks we just removed, so its index is unchanged. Message is a struct,
          # so we must reassign the updated value back into the array.
          summary = @messages[summary_idx]
          summary.thinking_count += thinking
          summary.tool_count += tool
          @messages[summary_idx] = summary
        else
          summary = Message.new("step_summary", "")
          summary.thinking_count = thinking
          summary.tool_count = tool
          @messages.insert(turn_start + 1, summary)
        end
      end

      # Cross-turn trim: collapse every turn older than `keep_recent_turns`
      # into a single `step_summary` line, freeing the retained tool/thinking
      # payloads (tool previews already cap at ~1 KB each, but over hundreds
      # of turns this still adds up — see plans/TOOLS-LEAKS.md §B1). Non-step
      # messages (assistant text, status, plan boxes) are preserved.
      private def merge_old_turns : Nil
        keep_turns = @keep_recent_turns
        return if keep_turns <= 0

        user_indices = [] of Int32
        @messages.each_with_index do |m, idx|
          user_indices << idx if m.role == "user"
        end
        return if user_indices.size <= keep_turns

        # Build (user_idx, next_user_idx) ranges for the turns we collapse
        # (all except the last `keep_turns`). Process in REVERSE so the
        # deletions/insertions inside a turn don't invalidate the ranges
        # of the still-to-process (earlier) turns.
        collapse_count = user_indices.size - keep_turns
        ranges = [] of {Int32, Int32}
        collapse_count.times do |i|
          u_idx = user_indices.unsafe_fetch(i)
          n_idx = i + 1 < user_indices.size ? user_indices.unsafe_fetch(i + 1) : @messages.size
          ranges << {u_idx, n_idx}
        end

        ranges.reverse_each do |user_idx, next_user_idx|
          thinking = 0
          tool = 0
          to_delete = [] of Int32

          (user_idx + 1...next_user_idx).each do |i|
            msg = @messages[i]
            case msg.role
            when "thinking"
              thinking += 1
              to_delete << i
            when "tool"
              tool += 1
              to_delete << i
            when "step_summary"
              # Fold any pre-existing summary's counts into the fresh one.
              thinking += msg.thinking_count
              tool += msg.tool_count
              to_delete << i
            end
          end

          next if to_delete.empty?

          to_delete.reverse.each { |i| @messages.delete_at(i) }

          summary = Message.new("step_summary", "")
          summary.thinking_count = thinking
          summary.tool_count = tool
          @messages.insert(user_idx + 1, summary)
        end
      end

      private def render_step_summary(msg : Message) : Array(String)
        lines = [] of String
        parts = [] of String

        if msg.thinking_count > 0
          t = msg.thinking_count == 1 ? "time" : "times"
          parts << "thinking #{msg.thinking_count} #{t}"
        end

        if msg.tool_count > 0
          t = msg.tool_count == 1 ? "tool" : "tools"
          parts << "call #{msg.tool_count} #{t}"
        end

        unless parts.empty?
          lines << ""
          lines << "#{ANSI.color(@theme.colors.dim, nil)}\u2026 #{parts.join(", ")}#{ANSI.reset}"
        end

        lines
      end

      private def read_keep_recent_steps : Int32
        raw = ENV[KEEP_RECENT_STEPS_ENV]?
        return DEFAULT_KEEP_RECENT_STEPS unless raw

        value = raw.to_i?
        return DEFAULT_KEEP_RECENT_STEPS unless value
        return DEFAULT_KEEP_RECENT_STEPS if value < 0

        value
      end

      private def read_keep_recent_turns : Int32
        raw = ENV[KEEP_RECENT_TURNS_ENV]?
        return DEFAULT_KEEP_RECENT_TURNS unless raw

        value = raw.to_i?
        return DEFAULT_KEEP_RECENT_TURNS unless value
        return DEFAULT_KEEP_RECENT_TURNS if value < 0

        value
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

      private def render_provider_panel(cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{@provider_list.title}#{ANSI.reset}"

        start, count = @provider_list.visible_window
        if @provider_list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = @provider_list.items[i]
          info = LLM::KNOWN_PROVIDERS.find { |p| p.name == item }
          desc = info.try(&.description) || ""
          marker = item == @provider_name ? " (active)" : ""
          line_text = "#{item.ljust(8)} #{desc}#{marker}"
          line_text = CharWidth.truncate_to_width(line_text, cols - 6)
          if i == @provider_list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{line_text}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{line_text}#{ANSI.reset}"
          end
        end
        if @provider_list.scrolled_down?
          remaining = @provider_list.items.size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def render_model_panel(cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{@model_list.title}#{ANSI.reset}"

        start, count = @model_list.visible_window
        if @model_list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = CharWidth.truncate_to_width(@model_list.items[i], cols - 4)
          marker = item == @model ? " (active)" : ""
          if i == @model_list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{item}#{marker}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{item}#{marker}#{ANSI.reset}"
          end
        end
        if @model_list.scrolled_down?
          remaining = @model_list.items.size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def render_select_panel(list : SelectList, cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{list.title}#{ANSI.reset}"

        active = case list
                 when @permission_list then @permission_mode
                 when @effort_list     then @on_get_effort.try(&.call) || "off"
                 when @theme_list      then @theme.name
                 else                       ""
                 end

        start, count = list.visible_window
        if list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = CharWidth.truncate_to_width(list.items[i], cols - 4)
          marker = item == active ? " (active)" : ""
          if i == list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{item}#{marker}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{item}#{marker}#{ANSI.reset}"
          end
        end
        if list.scrolled_down?
          remaining = list.items.size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def render_approval_panel(req : ApprovalRequest, cols : Int32) : Array(String)
        lines = [] of String
        lines << ""

        if danger = req.danger
          lines << "#{ANSI.color(@theme.colors.error, nil)}#{ANSI.bold}  ! DANGER: #{danger}#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.warning, nil)}#{ANSI.bold}  Approve #{req.tool_name}?#{ANSI.reset}"

        tool_preview(req.tool_name, req.args).each do |l|
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{l}#{ANSI.reset}"
        end

        lines << ""
        lines << "#{ANSI.color(@theme.colors.muted, nil)}  [y] once  [s] session  [n] reject  [Esc] reject#{ANSI.reset}"
        lines
      end

      private def tool_preview(name : String, args : String) : Array(String)
        parsed = JSON.parse(args)
        case name
        when "Bash"
          cmd = parsed["command"]?.try(&.to_s) || ""
          # Mirror ShellExecutionComponent in the JS TUI: split the command
          # by `\n` so each source line is its own entry in the returned
          # array (1 entry == 1 terminal row, the renderer invariant). The
          # caller wraps each entry in dim + a 2-space indent; the first
          # line carries the `$ ` prompt, continuations carry a 2-space
          # prefix so they line up under the command body. Cap at
          # TOOL_PREVIEW_LINES so a giant script doesn't flood the transcript.
          cmd_lines = cmd.split('\n')
          shown = cmd_lines.size > TOOL_PREVIEW_LINES ? cmd_lines[0...TOOL_PREVIEW_LINES] : cmd_lines
          Array(String).new(shown.size) do |i|
            i == 0 ? "$ #{shown[i]}" : "  #{shown[i]}"
          end
        when "Read", "Write", "Edit"
          path = (parsed["path"]? || parsed["filePath"]?).try(&.to_s) || ""
          ["file: #{path}"]
        when "Glob"
          pattern = parsed["pattern"]?.try(&.to_s) || ""
          ["pattern: #{pattern}"]
        when "Grep"
          pattern = parsed["pattern"]?.try(&.to_s) || ""
          ["search: #{pattern}"]
        else
          [] of String
        end
      rescue
        [] of String
      end

      private def render_edit_diff(display : Tools::ToolDisplay?, args : String) : Array(String)
        # Prefer the structured display carried on the tool result (populated
        # by the Edit tool itself); fall back to parsing the raw `tool_args`
        # for sessions recorded before the display channel existed. Both the
        # snake_case canonical names (`old_string`/`new_string`, as declared
        # in the Edit schema) and the legacy camelCase aliases are accepted,
        # mirroring `extract_key_argument`'s `path`/`filePath` form.
        old_str = ""
        new_str = ""

        if display
          old_str = display.before || ""
          new_str = display.after || ""
        else
          parsed = JSON.parse(args)
          old_str = (parsed["old_string"]? || parsed["oldString"]?).try(&.to_s) || ""
          new_str = (parsed["new_string"]? || parsed["newString"]?).try(&.to_s) || ""
        end

        lines = [] of String

        old_lines = old_str.split('\n')
        new_lines = new_str.split('\n')

        old_lines.each do |l|
          lines << "#{ANSI.color(@theme.colors.error, nil)}  - #{l}#{ANSI.reset}"
        end
        new_lines.each do |l|
          lines << "#{ANSI.color(@theme.colors.success, nil)}  + #{l}#{ANSI.reset}"
        end

        lines
      rescue
        [] of String
      end

      private def tool_header(name : String, args : String?, tool_result : String?,
                              has_result : Bool, is_error : Bool) : String
        bullet =
          if is_error
            "#{ANSI.color(@theme.colors.error, nil)}✗ #{ANSI.reset}"
          elsif has_result
            "#{ANSI.color(@theme.colors.success, nil)}● #{ANSI.reset}"
          else
            "#{ANSI.color(@theme.colors.text, nil)}● #{ANSI.reset}"
          end

        if name == "Bash"
          label = has_result ? "Ran a command" : "Running a command"
          tone = is_error ? @theme.colors.error : @theme.colors.primary
          return "#{bullet}#{ANSI.color(tone, nil)}#{ANSI.bold}#{label}#{ANSI.reset}"
        end

        verb = has_result ? "Used" : "Using"
        key_arg = extract_key_argument(name, args)
        tool_label = "#{ANSI.color(@theme.colors.primary, nil)}#{ANSI.bold}#{name}#{ANSI.reset}"
        arg_str = key_arg ? "#{ANSI.color(@theme.colors.dim, nil)} (#{key_arg})#{ANSI.reset}" : ""
        chip_str = ""

        if name == "Read" && has_result && !is_error
          if result = tool_result
            lines_count = count_non_empty_lines(result)
            chip_str = "#{ANSI.color(@theme.colors.dim, nil)} · #{lines_count} #{lines_count == 1 ? "line" : "lines"}#{ANSI.reset}"
          end
        end

        "#{bullet}#{verb} #{tool_label}#{arg_str}#{chip_str}"
      end

      private def extract_key_argument(name : String, args : String?) : String?
        return nil unless args
        parsed = JSON.parse(args)
        case name
        when "Read", "Write", "Edit"
          path = parsed["filePath"]?.try(&.to_s) || parsed["path"]?.try(&.to_s)
          return path if path && !path.empty?
        when "Glob", "Grep"
          pattern = parsed["pattern"]?.try(&.to_s)
          return pattern if pattern && !pattern.empty?
        end
        nil
      rescue
        nil
      end

      private def wrap_text(text : String, max_width : Int32) : Array(String)
        return [""] if text.empty?
        max_width = 1 if max_width < 1

        text.split('\n').flat_map do |line|
          line_w = CharWidth.visible_width(line)
          if line_w <= max_width
            [line]
          else
            words = line.split(' ')
            result = [] of String
            current = String::Builder.new
            current_w = 0

            words.each do |word|
              w = CharWidth.visible_width(word)
              # Hard-break a single token wider than max_width so it can't
              # overflow the column (CJK / long paths / no-space strings).
              if w > max_width
                if current_w > 0
                  result << current.to_s
                  current = String::Builder.new
                  current_w = 0
                end
                CharWidth.slice_into_width_chunks(word, max_width).each do |chunk|
                  result << chunk
                end
                next
              end

              sep = current_w > 0 ? 1 : 0
              if current_w + sep + w > max_width && current_w > 0
                result << current.to_s
                current = String::Builder.new
                current_w = 0
              end
              current << ' ' if current_w > 0
              current << word
              current_w += (current_w > 0 ? 1 : 0) + w
            end
            result << current.to_s if current_w > 0
            result
          end
        end.to_a
      end
    end
  end
end
