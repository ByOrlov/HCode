module Hcode
  module TUI
    struct ReadGroupEntry
      property tool_call_id : String
      property tool_args : String
      property tool_result : String?
      property is_error : Bool = false

      def initialize(@tool_call_id : String, @tool_args : String)
      end
    end

    struct Message
      property role : String
      property content : String
      property tool_call_id : String = ""
      property tool_name : String?
      property tool_args : String?
      property tool_result : String?
      property is_error : Bool = false
      property? expanded : Bool = false
      property step : Int32 = 0
      property read_group : Array(ReadGroupEntry)?
      # Used only by `role == "step_summary"` messages.
      property thinking_count : Int32 = 0
      property tool_count : Int32 = 0

      def initialize(@role : String, @content : String = "")
      end
    end

    struct ApprovalRequest
      property tool_name : String
      property args : String
      property danger : String?

      def initialize(@tool_name : String, @args : String, @danger : String?)
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
      @queue : Array(String) = [] of String
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

      # Approval state
      @approval_pending : ApprovalRequest?
      @approval_channel = Channel(Permission::ApprovalChoice).new
      @markdown : Markdown
      @provider_list : SelectList
      @model_list : SelectList
      @session_list : SelectList
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

      def initialize(
        @terminal : Terminal = Terminal.current,
        @theme : Theme = Theme.dark,
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
        @help_panel = HelpPanel.new(@theme)
        @work_dir = Dir.current
        @git_branch = detect_git_branch
        @keep_recent_steps = read_keep_recent_steps
      end

      def run(initial_prompt : String? = nil, &run_turn : String -> Nil) : Nil
        @terminal.raw!
        @terminal.refresh_size

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
          submit_message(ip, run_turn)
        end

        while @running
          key = @input.read_key

          if key
            handle_key(key, run_turn)
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

      def add_message(role : String, content : String) : Nil
        @messages << Message.new(role, content)
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
            msg.tool_args = event.tool_args
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
                  entry.tool_result = event.text
                  entry.is_error = event.is_error
                  group[eidx] = entry
                  msg.read_group = group
                  @messages[i] = msg
                  break
                end
              elsif msg.tool_call_id == event.tool_call_id
                msg.tool_result = event.text
                msg.is_error = event.is_error
                @messages[i] = msg
                break
              end
            end
            i -= 1
          end
          @streaming_tool = nil
          @status = thinking_status
          merge_turn_steps
        when .info?
          @status = event.text
        when .error?
          @messages << Message.new("error", event.text)
          @spinner.stop
          @status = ""
        end

        @dirty = true
      end

      def request_approval(tool_name : String, args : String, danger : String?) : Permission::ApprovalChoice
        @approval_pending = ApprovalRequest.new(tool_name, args, danger)
        @dirty = true
        select
        when choice = @approval_channel.receive
          @approval_pending = nil
          @dirty = true
          choice
        end
      end

      private def handle_key(key : KeyEvent, run_turn : String -> Nil) : Nil
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
          if !@agent_busy
            if pasted = @pasted_block
              editor_text = @editor.text
              if editor_text.includes?(paste_marker)
                final_text = editor_text.sub(paste_marker, pasted)
                @pasted_block = nil
                @pasted_lines = 0
                @editor.clear

                if final_text.starts_with?('/')
                  handle_slash_command(final_text, run_turn)
                else
                  submit_message(final_text, run_turn)
                end
              elsif !@editor.empty?
                text = @editor.submit!

                if text.starts_with?('/')
                  handle_slash_command(text, run_turn)
                else
                  submit_message(text, run_turn)
                end
              end
            elsif !@editor.empty?
              text = @editor.submit!

              if text.starts_with?('/')
                handle_slash_command(text, run_turn)
              else
                submit_message(text, run_turn)
              end
            end
          end
        when .ctrl_s?
          if @agent_busy && !@editor.empty?
            text = @editor.submit!
            @queue << text
            @messages << Message.new("system", "[Queued: #{text[0...40]}...]")
            @dirty = true
          end
        when .ctrl_o?
          last_expandable = @messages.reverse.find { |m|
            m.role == "thinking" || (m.role == "tool" && (m.tool_result || (m.read_group && m.read_group.not_nil!.any?(&.tool_result))))
          }
          if last_expandable
            last_expandable.expanded = !last_expandable.expanded?
            @dirty = true
          end
        when .ctrl_g?
          handle_external_editor
        when .up?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected - 1 + @command_hints.size) % @command_hints.size
            @dirty = true
          elsif @editor.empty? || @agent_busy
            @scroll_offset += 1 if @agent_busy
            @dirty = true
          else
            @editor.handle_input(key)
          end
        when .down?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected + 1) % @command_hints.size
            @dirty = true
          elsif @editor.empty? || @agent_busy
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
          if !@agent_busy
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
          if !@agent_busy
            @editor.handle_input(key)
            update_command_hints
          end
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

      private def submit_message(text : String, run_turn : String -> Nil) : Nil
        text = text.strip
        return if text.empty?

        @messages << Message.new("user", text)
        @current_step = 0
        @step_tool_count = 0
        @agent_busy = true
        @status = "Thinking..."
        @scroll_offset = 0
        @spinner.start
        @dirty = true

        spawn do
          run_turn.call(text)
          @agent_busy = false
          @spinner.stop
          @status = ""
          @dirty = true

          unless @queue.empty?
            next_msg = @queue.shift
            @messages << Message.new("user", next_msg)
            @current_step = 0
            @step_tool_count = 0
            @agent_busy = true
            @status = "Thinking..."
            @spinner.start
            @dirty = true
            spawn do
              run_turn.call(next_msg)
              @agent_busy = false
              @spinner.stop
              @dirty = true
            end
          end
        end
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

      private def handle_slash_command(input : String, run_turn : String -> Nil) : Nil
        parsed = CommandRegistry.parse(input)
        unless parsed
          submit_message(input, run_turn)
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
          @on_new_session.try(&.call)
          @messages.clear
          @messages << Message.new("system", "New session started.")
        when "/sessions", "/resume"
          open_session_selector(:resume)
        when "/restore"
          open_session_selector(:restore)
        when "/fork"
          if cb = @on_fork
            cb.call
            @messages << Message.new("system", "Session forked.")
          else
            @messages << Message.new("error", "Session fork is not wired up.")
          end
        when "/archive"
          if cb = @on_archive
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
          @on_clear.try(&.call)
          @messages.clear
          @messages << Message.new("system", "Conversation cleared.")
        when "/compact"
          @messages << Message.new("system", "Compacting context...")
          @dirty = true
          @on_compact.try(&.call)
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
          @on_undo.try(&.call)
          @messages << Message.new("system", "Undid last turn.")
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
            @messages << Message.new("system", "Current theme: #{@theme.name}. Usage: /theme dark|light")
          elsif args == "dark"
            @theme = Theme.dark
            @messages << Message.new("system", "Theme: dark")
          elsif args == "light"
            @theme = Theme.light
            @messages << Message.new("system", "Theme: light")
          else
            @messages << Message.new("error", "Unknown theme: #{args}. Available: dark, light")
          end
        else
          @messages << Message.new("error", "Unknown command: #{cmd}. Type /help for available commands.")
        end

        @show_command_hints = false
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
        label = entry.label
        preview = entry.preview.empty? ? "" : " — #{entry.preview}"
        time = entry.updated_at.to_s("%Y-%m-%d %H:%M")
        "#{label}#{preview}  (#{time})"
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
          item = @session_list.items[i]
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

      private def build_rendered_lines(cols : Int32) : {Array(String), Int32}
        new_lines = [] of String

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

        if @provider_list.visible?
          new_lines.concat(render_provider_panel(cols))
        end

        if @model_list.visible?
          new_lines.concat(render_model_panel(cols))
        end

        if @session_list.visible?
          new_lines.concat(render_session_panel(cols))
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
              if i == @command_hint_selected
                new_lines << "#{ANSI.color(@theme.colors.primary, nil)}#{ANSI.bold}  → #{hint.name.ljust(14)} #{hint.description}#{ANSI.reset}"
              else
                new_lines << "#{ANSI.color(@theme.colors.dim, nil)}    #{hint.name.ljust(14)} #{hint.description}#{ANSI.reset}"
              end
            end
          end
        end

        new_lines << render_footer(cols)

        if @exit_confirm
          new_lines << "#{ANSI.color(@theme.colors.warning, nil)} Press #{@exit_key} to exit#{ANSI.reset}"
        end

        {new_lines, editor_start + 1}
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

        cursor_row, cursor_col = @editor.cursor_position

        target_row = {editor_content_line + cursor_row, new_size - 1}.min
        row_delta = target_row - @hardware_cursor_row
        if row_delta > 0
          output << "\e[#{row_delta}B"
        elsif row_delta < 0
          output << "\e[#{-row_delta}A"
        end

        editor_text_col = 5 + cursor_col
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
              lines.concat(render_read_group(group, name, msg.expanded?, cols))
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
                  render_edit_diff(args).each { |l| lines << l }
                end
              end
              if result = msg.tool_result
                result_lines = result.split('\n')
                max_lines = msg.expanded? ? 200 : 10
                shown = result_lines.first(max_lines)
                shown.each do |l|
                  lines << "#{ANSI.color(@theme.colors.tool_result, nil)}  #{l}#{ANSI.reset}"
                end
                if result_lines.size > max_lines
                  lines << "#{ANSI.color(@theme.colors.dim, nil)}  ... (#{result_lines.size - max_lines} more, Ctrl+O to #{msg.expanded? ? "collapse" : "expand"})#{ANSI.reset}"
                end
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
          if line.size <= max_width
            [line]
          else
            words = line.split(' ')
            result = [] of String
            current = String::Builder.new
            current_w = 0

            words.each do |word|
              w = word.size
              sep = current_w > 0 ? 1 : 0
              if current_w + sep + w > max_width && current_w > 0
                result << current.to_s
                current = String::Builder.new
                current_w = 0
              end
              current << ' ' if current_w > 0
              current << word
              current_w += sep + w
            end
            result << current.to_s
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

      private def render_welcome_box(cols : Int32) : Array(String)
        box_w = cols
        inner_w = box_w - 4

        logo_lines = [
          "  ▐█▛█▛█▌  ",
          "▐█████████▌",
          "▐█▙▄▄▄▄▄▟█▌",
        ]

        lines = [] of String

        bc = ANSI.color(@theme.colors.border, nil)
        ac = ANSI.color(@theme.colors.primary, nil)
        mc = ANSI.color(@theme.colors.muted, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        r = ANSI.reset

        lines << "#{bc}╭#{"─" * (box_w - 2)}╮#{r}"

        welcome_text = "#{ANSI.bold}Welcome to HCode!#{r}"
        content_w = visible_len(welcome_text)
        used = 2 + logo_lines[0].size + 2 + content_w
        pad = inner_w + 2 - used
        pad = 1 if pad < 1
        lines << "#{bc}│#{r}  #{ac}#{logo_lines[0]}#{r}  #{tc}#{welcome_text}#{" " * pad}#{bc}│#{r}"

        help_text = "Send /help for help information."
        used = 2 + logo_lines[1].size + 2 + help_text.size
        pad = inner_w + 2 - used
        pad = 1 if pad < 1
        lines << "#{bc}│#{r}  #{ac}#{logo_lines[1]}#{r}  #{mc}#{help_text}#{" " * pad}#{bc}│#{r}"

        mouth_text = ""
        used = 2 + logo_lines[2].size + 2 + mouth_text.size
        pad = inner_w + 2 - used
        pad = 1 if pad < 1
        lines << "#{bc}│#{r}  #{ac}#{logo_lines[2]}#{r}  #{tc}#{mouth_text}#{" " * pad}#{bc}│#{r}"

        lines << "#{bc}│#{r}#{" " * (box_w - 2)}#{bc}│#{r}"

        info = [
          {"Directory", @work_dir},
          {"Session", @session_id.empty? ? "new" : @session_id},
          {"Model", @model},
          {"Version", VERSION},
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

      private def render_editor_box(cols : Int32) : Array(String)
        box_w = cols
        bc = ANSI.color(@theme.colors.border, nil)
        pc = ANSI.color(@theme.colors.primary, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset

        lines = [] of String

        top = "#{bc}╭#{"─" * (box_w - 2)}╮#{r}"
        bot = "#{bc}╰#{"─" * (box_w - 2)}╯#{r}"
        lines << top

        if @editor.empty?
          content = "#{bc}│#{r} #{pc}#{ANSI.bold}>#{r} #{dc}Send a message...#{r} #{tc}#{ANSI.bold} #{r}"
          pad = box_w - 2 - visible_len(content)
          pad = 0 if pad < 0
          lines << "#{content}#{" " * pad}#{bc}│#{r}"
        else
          cursor_row, cursor_col = @editor.cursor_position
          editor_lines = @editor.text.split('\n')
          editor_lines.each_with_index do |eline, i|
            prefix = i == 0 ? "#{bc}│#{r} #{pc}#{ANSI.bold}>#{r} " : "#{bc}│#{r}   "

            if i == cursor_row
              before = eline[0...cursor_col]? || ""
              char_at = eline[cursor_col]? || " "
              after = eline[(cursor_col + 1)..]? || ""
              content = "#{prefix}#{tc}#{before}#{r}#{ANSI.color(nil, @theme.colors.primary)}#{char_at}#{r}#{tc}#{after}#{r}"
            else
              content = "#{prefix}#{tc}#{eline}#{r}"
            end

            pad = box_w - 2 - visible_len(content)
            pad = 0 if pad < 0
            lines << "#{content}#{" " * pad}#{bc}│#{r}"
          end
        end

        lines << bot
        lines
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
        right = ctx_str

        gap = cols - visible_len(left) - visible_len(right)
        gap = 1 if gap < 1

        "#{ANSI.color(@theme.colors.dim, nil)}#{left}#{" " * gap}#{right}#{ANSI.reset}"
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
        clean = s.gsub(/\e\[[0-9;]*m/, "")
        clean.size
      end

      # Collapse older intermediate thinking/tool blocks within the current turn
      # into a single muted summary line, keeping the most recent N steps visible.
      # Mirrors the TypeScript TUI's `mergeCurrentTurnSteps`.
      private def merge_turn_steps : Nil
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
          if i == @provider_list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{item.ljust(8)} #{desc}#{marker}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{item.ljust(8)} #{desc}#{marker}#{ANSI.reset}"
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
          item = @model_list.items[i]
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
          ["$ #{cmd}"]
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

      private def render_edit_diff(args : String) : Array(String)
        parsed = JSON.parse(args)
        old_str = parsed["oldString"]?.try(&.to_s) || ""
        new_str = parsed["newString"]?.try(&.to_s) || ""
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

        text.split('\n').flat_map do |line|
          if line.size <= max_width
            [line]
          else
            words = line.split(' ')
            result = [] of String
            current = String::Builder.new
            current_w = 0

            words.each do |word|
              w = word.size
              sep = current_w > 0 ? 1 : 0
              if current_w + sep + w > max_width && current_w > 0
                result << current.to_s
                current = String::Builder.new
                current_w = 0
              end
              current << ' ' if current_w > 0
              current << word
              current_w += sep + w
            end
            result << current.to_s
          end
        end.to_a
      end
    end
  end
end
