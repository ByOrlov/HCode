module Hcode
  module TUI
    module InputController
      # Maximum number of slash-command hints rendered at once. The list scrolls
      # when there are more matches, keeping the selection always visible.
      COMMAND_HINT_MAX = 10

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
          # While the model selector is open in the Model step it owns input;
          # ESC closes the selector first, a second ESC steps back.
          if @model_list.visible?
            handle_setup_model_key(key)
            return
          end
          case key.key
          when .enter?
            wizard = @wizard
            step = wizard.try(&.step)
            # On endpoint/model an empty Enter keeps the default. Credentials
            # requires a non-empty key, so the submit gate stays there.
            if step == Setup::Wizard::Step::Endpoint || step == Setup::Wizard::Step::Model
              text = @editor.empty? ? "" : @editor.submit!
              submit_setup_text(text)
            elsif !@editor.empty?
              text = @editor.submit!
              submit_setup_text(text)
            end
          when .escape?, .ctrl_d?
            back_setup_step
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

        if @plan_review_dialog.visible?
          @plan_review_dialog.rows = @terminal.rows
          @plan_review_dialog.terminal_width = @terminal.cols
          @plan_review_dialog.handle_input(key)
          @dirty = true
          return
        end

        if @help_panel.visible?
          handle_help_key(key)
          return
        end

        if @usage_panel.visible?
          if @usage_panel.handle_input(key)
            @dirty = true
          end
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

        if @sudo_list.visible?
          handle_sudo_list_key(key)
          return
        end

        if @sudo_approval_list.visible?
          handle_sudo_approval_key(key)
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
          if !@editor.empty?
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
          elsif !@queue.empty?
            steer_queued
          end
        when .ctrl_g?
          handle_external_editor
        when .up?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected - 1 + @command_hints.size) % @command_hints.size
            @dirty = true
          else
            @editor.handle_input(key)
          end
        when .down?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected + 1) % @command_hints.size
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
          else
            toggle_plan_mode
          end
        when .escape?
          if @agent_busy
            @status = "Cancelling..."
            @dirty = true
            @on_cancel.try(&.call)
          elsif !@editor.empty?
            @editor.clear
            update_command_hints
          end
        when .paste?
          if text = key.text
            paste_lines = text.count('\n') + 1
            if paste_lines > 10 || text.size > 1000
              @editor.insert_paste_marker(text, paste_lines)
            else
              @editor.insert_text(text)
            end
            update_command_hints
          end
        when .ctrl_e?
          @editor.expand_markers
        when .backspace?
          @editor.handle_input(key)
          update_command_hints
        when .delete?
          @editor.handle_input(key)
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

      private def update_command_hints : Nil
        text = @editor.text
        if text.starts_with?('/') && !text.includes?(' ')
          matches = CommandRegistry.match(text)
          if matches.size > 0
            @show_command_hints = true
            @command_hints = matches
            @command_hint_selected = {@command_hint_selected, matches.size - 1}.min
            @command_hint_scroll = 0
          else
            @show_command_hints = false
          end
        else
          @show_command_hints = false
        end
      end

      # Compute the visible window [start, count) for command hints, mirroring
      # `SelectList#visible_window`: adjust `@command_hint_scroll` so the
      # selected row is always on screen.
      private def command_hint_window : {Int32, Int32}
        size = @command_hints.size
        return {0, 0} if size == 0
        mv = {COMMAND_HINT_MAX, size}.min
        if @command_hint_selected < @command_hint_scroll
          @command_hint_scroll = @command_hint_selected
        elsif @command_hint_selected >= @command_hint_scroll + mv
          @command_hint_scroll = {@command_hint_selected - mv + 1, 0}.max
        end
        max_offset = {size - mv, 0}.max
        @command_hint_scroll = {@command_hint_scroll, max_offset}.min
        {@command_hint_scroll, mv}
      end

      private def handle_external_editor : Nil
        editor_cmd = ENV["EDITOR"]? || ENV["VISUAL"]? || "vim"
        tmp_dir = ENV["TMPDIR"]? || "/tmp"
        tmp_file = File.join(tmp_dir, "hcode-edit-#{Random::Secure.hex(4)}.md")
        File.write(tmp_file, @editor.expanded_text)

        @terminal.restore!

        Process.run("#{editor_cmd} #{tmp_file}", shell: true)

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

      # Toggle Plan mode on/off (wired to both `/plan` and the Tab shortcut).
      # Mirrors the TS rule: tools that mutate state are blocked while on, so
      # the agent only researches. Returns to normal mode on the next toggle.
      # The active state is signalled visually by the input frame colour and
      # the placeholder text, not by a transcript system message.
      private def toggle_plan_mode : Nil
        cb = @on_plan_mode
        if cb.nil?
          @messages << Message.new("error", Hcode.t("ui.plan_not_wired"))
          return
        end
        desired = !@plan_mode
        if cb.call(desired)
          @plan_mode = desired
        else
          # Callback exists but failed (e.g. service raised). Sync from the
          # service when possible so the flag tracks reality instead of
          # flipping blindly, and surface a distinct error.
          @messages << Message.new("error", Hcode.t("ui.plan_toggle_failed"))
        end
      end

      # `/debugzones`: toggle an overlay showing the current log-zone and
      # active-zone line counts on the last rendered row, so zone-size
      # regressions (overflow, wrong split) are visible at a glance.
      private def toggle_debug_zones : Nil
        @debug_zones = !@debug_zones
        @on_debug_zones_change.try(&.call(@debug_zones))
        state = @debug_zones ? Hcode.t("ui.debugzones_on") : Hcode.t("ui.debugzones_off")
        @messages << Message.new("system", "#{Hcode.t("commands.debugzones")}: #{state}")
      end

      private def handle_slash_command(input : String) : Nil
        parsed = CommandRegistry.parse(input)
        unless parsed
          submit_message(input)
          return
        end

        parsed = parsed || raise "parsed should not be nil"
        cmd = parsed.command
        args = parsed.args

        # Plugin slash commands: `/<plugin_id>:<command> [args]`
        if cmd.includes?(':')
          if handle_plugin_command(cmd, args)
            return
          end
        end

        case cmd
        when "/help"
          open_help_panel
        when "/exit", "/quit"
          cmd_exit
          return
        when "/new"
          cmd_new
        when "/sessions", "/resume"
          cmd_sessions
        when "/restore"
          cmd_restore
        when "/fork"
          cmd_fork
        when "/archive"
          cmd_archive
        when "/rename", "/title"
          cmd_rename(args)
        when "/clear"
          cmd_clear
        when "/compact"
          cmd_compact
        when "/status"
          cmd_status
        when "/undo"
          cmd_undo(args)
        when "/queue"
          cmd_queue(args)
        when "/yolo"
          cmd_yolo
        when "/auto"
          cmd_auto
        when "/manual"
          cmd_manual
        when "/model"
          open_model_selector
        when "/provider"
          open_provider_selector
        when "/export-md"
          cmd_export_md(args)
        when "/add-dir"
          cmd_add_dir(args)
        when "/theme"
          cmd_theme(args)
        when "/version"
          cmd_version
        when "/upgrade"
          cmd_upgrade
        when "/usage"
          cmd_usage
        when "/editor"
          handle_external_editor
        when "/copy"
          cmd_copy
        when "/permission"
          cmd_permission(args)
        when "/sudo"
          cmd_sudo(args)
        when "/sounds"
          cmd_sounds(args)
        when "/volume"
          cmd_volume(args)
        when "/effort"
          cmd_effort(args)
        when "/plan"
          toggle_plan_mode
        when "/swarm"
          handle_swarm_command(args)
        when "/todos"
          cmd_todos(args)
        when "/debug"
          cmd_debug
        when "/debugzones"
          toggle_debug_zones
        when "/feedback"
          cmd_feedback(args)
        when "/reload"
          cmd_reload
        when "/web"
          cmd_web
        when "/settings"
          cmd_settings
        when "/init"
          cmd_init
        when "/export-debug-zip"
          cmd_export_debug_zip
        when "/experiments"
          cmd_experiments
        when "/mcp"
          cmd_mcp(args)
        when "/plugins"
          handle_plugins_command(args)
        when "/login"
          cmd_login
        when "/logout"
          cmd_logout
        when "/tasks", "/task"
          open_tasks_browser
        when "/memory"
          cmd_memory
        when "/goal"
          handle_goal_command(args)
        when "/language"
          handle_language_command(args)
        else
          @messages << Message.new("error", Hcode.t("ui.unknown_command", cmd: cmd))
        end

        @show_command_hints = false
        invalidate_log_cache!
        @dirty = true
      end

      private def handle_swarm_command(args : String) : Nil
        service = Hcode::Tools::SwarmMode.service
        unless service
          @messages << Message.new("error", Hcode.t("ui.swarm_not_wired"))
          return
        end

        sub = args.strip.downcase
        case sub
        when "on"
          enable_swarm_mode(service, Hcode::Tools::SwarmTrigger::Manual)
        when "off"
          disable_swarm_mode(service)
        when ""
          service.active? ? disable_swarm_mode(service) : enable_swarm_mode(service, Hcode::Tools::SwarmTrigger::Manual)
        else
          # `/swarm <prompt>`: a one-shot swarm task. Enters with the `task`
          # trigger so `Loop::Agent` auto-exits (and leaves an exit-reminder)
          # at the end of this turn.
          if @agent_busy
            @messages << Message.new("error", Hcode.t("ui.swarm_busy"))
            return
          end
          service.enter(Hcode::Tools::SwarmTrigger::Task)
          @messages << Message.new("system", Hcode.t("ui.swarm_task_started"))
          start_turn(args.strip)
        end
      end

      private def enable_swarm_mode(service : Hcode::Tools::SwarmModeService,
                                    trigger : Hcode::Tools::SwarmTrigger) : Nil
        if service.active?
          @messages << Message.new("system", Hcode.t("ui.swarm_already_on"))
          return
        end
        service.enter(trigger)
        @messages << Message.new("system", Hcode.t("ui.swarm_mode_state",
          state: Hcode.t("ui.swarm_mode_on")))
      end

      private def disable_swarm_mode(service : Hcode::Tools::SwarmModeService) : Nil
        unless service.active?
          @messages << Message.new("system", Hcode.t("ui.swarm_already_off"))
          return
        end
        service.exit
        @messages << Message.new("system", Hcode.t("ui.swarm_mode_state",
          state: Hcode.t("ui.swarm_mode_off")))
      end

      private def handle_plugins_command(args : String) : Nil
        if cb = @on_plugins_command
          result = cb.call(args)
          @messages << Message.new("system", result)
        else
          @messages << Message.new("system", "Plugin management is not available.")
        end
      end

      private def handle_plugin_command(cmd : String, args : String) : Bool
        # cmd is like "/<plugin_id>:<command>"
        full = cmd.lchop('/')
        plugin_id = full.split(':', 2)[0]?
        command_name = full.split(':', 2)[1]?

        return false unless plugin_id && command_name

        match = @plugin_commands.find do |c|
          c.plugin_id == plugin_id && c.name == command_name
        end
        return false unless match

        expanded = Hcode::Plugin::CommandLoader.expand_arguments(match.body, args)
        submit_message(expanded)
        true
      end

      private def handle_goal_command(args : String) : Nil
        service = Hcode::Tools::Goal.service
        unless service
          @messages << Message.new("error", "Goal service is not wired up.")
          return
        end

        sub = args.strip.downcase
        case sub
        when "", "status"
          snapshot = service.get_goal
          if snapshot
            @messages << Message.new("system", format_goal_snapshot(snapshot))
          else
            @messages << Message.new("system", Hcode.t("ui.no_active_goal"))
          end
        when "pause"
          begin
            snapshot = service.pause_goal
            @messages << Message.new("system", "#{Hcode.t("ui.goal_paused")}\n#{format_goal_snapshot(snapshot)}")
          rescue ex
            @messages << Message.new("error", Hcode.t("ui.cannot_pause", message: ex.message.to_s))
          end
        when "resume"
          begin
            snapshot = service.resume_goal
            @messages << Message.new("system", "#{Hcode.t("ui.goal_resumed")}\n#{format_goal_snapshot(snapshot)}")
          rescue ex
            @messages << Message.new("error", Hcode.t("ui.cannot_resume", message: ex.message.to_s))
          end
        when "cancel"
          begin
            snapshot = service.cancel_goal
            @messages << Message.new("system", "#{Hcode.t("ui.goal_cancelled")}\n#{format_goal_snapshot(snapshot)}")
          rescue ex
            @messages << Message.new("error", Hcode.t("ui.cannot_cancel", message: ex.message.to_s))
          end
        else
          @messages << Message.new("error", Hcode.t("ui.usage_goal"))
        end
      end

      private def format_goal_snapshot(s : Hcode::Tools::GoalSnapshot) : String
        String.build do |str|
          str << "#{Hcode.t("ui.goal_label")}: #{s.objective}\n"
          str << "#{Hcode.t("ui.goal_status")}: #{s.status}\n"
          str << "#{Hcode.t("ui.goal_id")}: #{s.goal_id}\n"
          if c = s.completion_criterion
            str << "#{Hcode.t("ui.goal_completion")}: #{c}\n"
          end
          if r = s.terminal_reason
            str << "#{Hcode.t("ui.goal_reason")}: #{r}\n"
          end
        end.strip
      end

      private def handle_language_command(args : String) : Nil
        supported = Hcode::I18n.available_locales
        lang = args.strip.downcase
        if lang.empty?
          current = @on_get_language.try(&.call) || Hcode::I18n.resolve_locale
          @messages << Message.new("system",
            "#{Hcode.t("ui.current_language", name: current)}\n" \
            "#{Hcode.t("ui.available_languages", list: supported.join(", "))}\n" \
            "#{Hcode.t("ui.usage_language", list: supported.join("|"))}")
          return
        end
        unless supported.includes?(lang)
          @messages << Message.new("error",
            Hcode.t("language.unknown", name: lang) + "\n" +
            Hcode.t("language.available", list: supported.join(", ")))
          return
        end
        @on_language_change.try(&.call(lang))
        Hcode::I18n.activate(lang)
        @messages << Message.new("system", Hcode.t("language.changed", name: lang))
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
        items = LLM::Provider.providers.map(&.name)
        @provider_list.show(Hcode.t("ui.select_provider"), items)
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
          elsif needs_setup?(name)
            # Credentials missing for the selected provider: launch the setup
            # wizard for it instead of failing the switch.
            start_setup_for_provider(name)
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

      # Does the named provider need the setup wizard? True when a configured
      # check is wired up and it reports the provider as not yet configured.
      private def needs_setup?(name : String) : Bool
        if cb = @on_provider_configured
          !cb.call(name)
        else
          false
        end
      end

      # Launch the setup wizard at runtime for an already-chosen provider. The
      # welcome message and provider selector are skipped: we already know the
      # provider, so the wizard drops straight into the Credentials step.
      private def start_setup_for_provider(name : String) : Nil
        wizard = Setup::Wizard.new
        wizard.select_provider(name)
        @wizard = wizard
        @setup_mode = true
        @provider_name = name
        @status = "Setup: #{wizard.step.to_s.downcase}"
        @editor.clear
        @messages << Message.new("user", provider_label(name))
        if wizard.step == Setup::Wizard::Step::Endpoint
          # Keyless provider: jump straight to endpoint, but still show a
          # transcript entry so the user knows why no key was asked.
          @messages << Message.new("system", "No API key needed for #{name}.")
        end
        advance_setup_step
      end

      private def provider_label(name : String) : String
        if choice = Setup::Wizard.choices.find { |c| c.name == name }
          choice.label
        else
          name
        end
      end

      PERMISSION_MODES = ["manual", "auto", "yolo"]
      EFFORT_LEVELS    = ["off", "low", "medium", "high"]
      THEMES           = ["dark", "light"]
      SUDO_MODES       = ["request", "always", "off"]

      private def open_permission_selector : Nil
        @permission_list.show(Hcode.t("ui.select_permission"), PERMISSION_MODES)
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
        @effort_list.show(Hcode.t("ui.select_effort"), EFFORT_LEVELS)
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
            cb.call(effort)
            @messages << Message.new("system", Hcode.t("ui.effort_set", name: effort))
          else
            @messages << Message.new("system", Hcode.t("ui.effort_not_wired"))
          end
        when .escape?
          @effort_list.hide
          @dirty = true
        end
      end

      private def open_theme_selector : Nil
        @theme_list.show(Hcode.t("ui.select_theme"), THEMES)
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
          @messages << Message.new("system", Hcode.t("ui.theme_set", name: name))
          invalidate_log_cache!
        when .escape?
          @theme_list.hide
          @dirty = true
        end
      end

      private def open_sudo_selector : Nil
        @sudo_list.show("Select sudo mode", SUDO_MODES)
        current = Tools::Bash.sudo_mode.to_s.downcase
        @sudo_list.selected = SUDO_MODES.index(current) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_sudo_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @sudo_list.handle_input(key)
          @dirty = true
        when .enter?
          mode_str = @sudo_list.current || "request"
          @sudo_list.hide
          @dirty = true
          mode = case mode_str
                 when "off"    then Tools::Bash::SudoMode::Off
                 when "always" then Tools::Bash::SudoMode::Always
                 else               Tools::Bash::SudoMode::Request
                 end
          Tools::Bash.sudo_mode = mode
          @messages << Message.new("system", "Sudo mode: #{mode_str}")
        when .escape?
          @sudo_list.hide
          @dirty = true
        end
      end

      private def handle_sudo_approval_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @sudo_approval_list.handle_input(key)
          @dirty = true
        when .enter?
          idx = @sudo_approval_list.selected
          choice = case idx
                   when 0 then Tools::Bash::SudoApprovalChoice::AllowOnce
                   when 1 then Tools::Bash::SudoApprovalChoice::AlwaysAllow
                   else        Tools::Bash::SudoApprovalChoice::Deny
                   end
          @sudo_approval_channel.send(choice)
        when .escape?
          @sudo_approval_channel.send(Tools::Bash::SudoApprovalChoice::Deny)
        end
      end

      private def open_session_selector(mode : Symbol) : Nil
        @session_picker_mode = mode
        include_archived = mode == :restore
        title = include_archived ? Hcode.t("ui.restore_session") : Hcode.t("ui.resume_session")

        # Scope to the current workspace so sessions from other folders don't
        # mix in. Falls back to all sessions when @work_dir is unset (e.g. in
        # tests or non-standard entry points).
        index = Session::Index.new(@home)
        ws_id = @work_dir.empty? ? nil : Session::Index.workspace_id(@work_dir)
        entries = index.list(ws_id, include_archived: include_archived)
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
              @model_list.show(Hcode.t("ui.select_model", name: @provider_name), models)
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
          # A single Esc clears an active search first; a second Esc closes.
          @model_list.clear_query || @model_list.hide
          @dirty = true
        else
          # ↑/↓, Backspace, and typed characters drive the fuzzy filter.
          @model_list.handle_input(key)
          @dirty = true
        end
      end
    end
  end
end
