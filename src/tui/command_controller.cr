# Slash-command handlers, mixed into `TUI::App`. Owns the per-command logic
# that was previously a single ~400-line `case` inside `handle_slash_command`.
# The dispatcher stays in `App#handle_slash_command`; each branch delegates
# here. Methods keep direct ivar access, matching `SetupController`.
module Hcode
  module TUI
    module CommandController
      private def cmd_exit : Nil
        @exit_confirm = true
        @dirty = true
      end

      private def cmd_new : Nil
        if @agent_busy
          @messages << Message.new("error", "Cannot start a new session while a turn is running. Wait or interrupt first.")
        else
          @on_new_session.try(&.call)
          @messages.clear
          @show_welcome = true
          @messages << Message.new("system", Hcode.t("ui.new_session_started"))
        end
      end

      private def cmd_sessions : Nil
        if @agent_busy
          @messages << Message.new("error", "Cannot switch sessions while a turn is running.")
        else
          open_session_selector(:resume)
        end
      end

      private def cmd_restore : Nil
        if @agent_busy
          @messages << Message.new("error", "Cannot restore a session while a turn is running.")
        else
          open_session_selector(:restore)
        end
      end

      private def cmd_fork : Nil
        if @agent_busy
          @messages << Message.new("error", "Cannot fork while a turn is running. Wait or interrupt first.")
        elsif cb = @on_fork
          cb.call
          @messages << Message.new("system", "Session forked.")
        else
          @messages << Message.new("error", "Session fork is not wired up.")
        end
      end

      private def cmd_archive : Nil
        if @agent_busy
          @messages << Message.new("error", "Cannot archive while a turn is running.")
        elsif cb = @on_archive
          cb.call
          @messages << Message.new("system", Hcode.t("ui.session_archived"))
        else
          @messages << Message.new("error", "Session archive is not wired up.")
        end
      end

      private def cmd_rename(args : String) : Nil
        if args.empty?
          @messages << Message.new("system", Hcode.t("ui.usage_rename"))
        elsif cb = @on_rename
          cb.call(args)
          @messages << Message.new("system", "Session title set to: #{args}")
        else
          @messages << Message.new("error", "Session rename is not wired up.")
        end
      end

      private def cmd_clear : Nil
        if @agent_busy
          @messages << Message.new("error", "Cannot clear while a turn is running. Wait or interrupt first.")
        else
          @on_clear.try(&.call)
          @messages.clear
          @show_welcome = true
          @messages << Message.new("system", Hcode.t("ui.conversation_cleared"))
        end
      end

      private def cmd_compact : Nil
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
      end

      private def cmd_status : Nil
        stats = String.build do |s|
          s << "#{Hcode.t("ui.status_model")}: #{@model}\n"
          s << "#{Hcode.t("ui.permission_label")}: #{@permission_mode}\n"
          if @max_context_tokens > 0
            s << "#{Hcode.t("ui.context_label")}: #{build_context_status.split(": ", 2)[1]? || ""}\n"
          else
            s << "#{Hcode.t("ui.context_label")}: #{@context_percent.round(1)}%\n"
          end
          s << "#{Hcode.t("ui.messages_label")}: #{@messages.size}\n"
          s << "#{Hcode.t("ui.queue_label")}: #{@queue.size}\n"
        end
        @messages << Message.new("system", stats.strip)
      end

      private def cmd_undo(args : String) : Nil
        if @agent_busy
          @messages << Message.new("error", Hcode.t("ui.cannot_undo_busy"))
        elsif args.strip.empty?
          open_undo_selector
        else
          count = args.strip.to_i? || 1
          @on_undo.try(&.call)
          @messages << Message.new("system", "Undid last #{count} turn(s).")
        end
      end

      private def cmd_queue(args : String) : Nil
        if args.strip == "clear"
          @queue.clear
          @messages << Message.new("system", Hcode.t("ui.queue_cleared"))
        elsif @queue.empty?
          @messages << Message.new("system", Hcode.t("ui.queue_empty"))
        else
          preview = @queue.map_with_index { |qm, i| "  #{i + 1}. #{truncate_preview(qm.text)}" }.join("\n")
          @messages << Message.new("system", "Queue (#{@queue.size}):\n#{preview}\n— #{queue_hint}")
        end
      end

      private def cmd_yolo : Nil
        @permission_mode = "yolo"
        @messages << Message.new("system", "Permission mode: yolo (auto-approve all)")
      end

      private def cmd_auto : Nil
        @permission_mode = "auto"
        @messages << Message.new("system", "Permission mode: auto (safe operations)")
      end

      private def cmd_manual : Nil
        @permission_mode = "manual"
        @messages << Message.new("system", "Permission mode: manual (approve each)")
      end

      private def cmd_export_md(args : String) : Nil
        path = args.empty? ? "session-#{Time.utc.to_unix}.md" : args
        @on_export.try(&.call(path))
        @messages << Message.new("system", Hcode.t("ui.exported_to", path: path))
      end

      private def cmd_add_dir(args : String) : Nil
        if args.empty?
          @messages << Message.new("system", Hcode.t("ui.usage_add_dir"))
        else
          path = File.expand_path(args.strip, @work_dir)
          unless Dir.exists?(path)
            @messages << Message.new("error", "Directory does not exist: #{path}")
          else
            if @additional_dirs.includes?(path)
              @messages << Message.new("system", "Already added: #{path}")
            else
              @additional_dirs << path
              on_additional_dirs_change.try(&.call(@additional_dirs.dup))
              @messages << Message.new("system",
                Hcode.t("ui.added_directory", path: path, count: @additional_dirs.size))
            end
          end
        end
      end

      private def cmd_theme(args : String) : Nil
        if args.empty?
          open_theme_selector
        elsif args == "dark"
          @theme = Theme.dark
          @messages << Message.new("system", Hcode.t("ui.theme_set", name: "dark"))
        elsif args == "light"
          @theme = Theme.light
          @messages << Message.new("system", Hcode.t("ui.theme_set", name: "light"))
        else
          @messages << Message.new("error", Hcode.t("ui.theme_unknown", name: args))
        end
      end

      private def cmd_version : Nil
        version = Hcode::VERSION
        build = Hcode.build_date || "dev"
        @messages << Message.new("system", "hcode #{version} (#{build})\nCrystal #{Crystal::VERSION}")
      end

      private def cmd_upgrade : Nil
        @messages << Message.new("system", Hcode.t("ui.upgrade_checking"))
        @dirty = true
        render
        ok, msg = Hcode::Upgrader.run
        Hcode::Upgrader.record_check(nil)
        @messages << Message.new(ok ? "system" : "error", msg)
      end

      private def cmd_usage : Nil
        @usage_panel.show
        @input.drain_pending_enters
        @show_command_hints = false
        @dirty = true
      end

      private def cmd_copy : Nil
        last_assistant = @messages.reverse.find { |m| m.role == "assistant" }
        if last_assistant
          copy_to_clipboard(last_assistant.content)
          @messages << Message.new("system", Hcode.t("ui.copied"))
        else
          @messages << Message.new("error", Hcode.t("ui.no_assistant_to_copy"))
        end
      end

      private def cmd_permission(args : String) : Nil
        case args.strip.downcase
        when "manual", "auto", "yolo"
          apply_permission_mode(args.strip.downcase)
        when ""
          open_permission_selector
        else
          @messages << Message.new("error", Hcode.t("ui.mode_unknown", name: args))
        end
      end

      private def cmd_effort(args : String) : Nil
        if args.empty?
          open_effort_selector
        elsif cb = @on_set_effort
          normalized = args.strip.downcase
          cb.call(normalized)
          @messages << Message.new("system", Hcode.t("ui.effort_set", name: normalized))
        else
          @messages << Message.new("system", Hcode.t("ui.effort_not_wired"))
        end
      end

      private def cmd_todos(args : String) : Nil
        todos = current_todos
        if todos.nil? || todos.empty?
          @messages << Message.new("system", Hcode.t("ui.no_todos"))
        elsif args.strip.downcase == "clear"
          @on_clear_todos.try(&.call)
          @messages << Message.new("system", Hcode.t("ui.todos_cleared"))
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
      end

      private def cmd_debug : Nil
        if cb = @on_debug
          cb.call
        else
          @messages << Message.new("error", "/debug is not wired up.")
        end
      end

      private def cmd_feedback(args : String) : Nil
        if args.strip.empty?
          @messages << Message.new("system", Hcode.t("ui.usage_feedback"))
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
      end

      private def cmd_reload : Nil
        if cb = @on_reload
          cb.call
          @messages << Message.new("system", "Config and session state reloaded.")
        else
          @messages << Message.new("error", "Reload is not wired up.")
        end
      end

      private def cmd_web : Nil
        url = "https://www.kimi.com/code?session=#{URI.encode_path(@session_id)}"
        @messages << Message.new("system", "Open in Web UI: #{url}")
      end

      private def cmd_settings : Nil
        settings = String.build do |s|
          s << "#{Hcode.t("info.provider_label", name: @provider_name)}\n"
          s << "#{Hcode.t("ui.status_model")}: #{@model}\n"
          s << "#{Hcode.t("ui.permission_label")}: #{@permission_mode}\n"
          s << "#{Hcode.t("ui.settings_theme")}: #{@theme.name}\n"
          effort = @on_get_effort.try(&.call) || "off"
          s << "#{Hcode.t("ui.settings_effort")}: #{effort}\n"
          s << "Home: #{@home}\n"
          s << "Work dir: #{@work_dir}\n"
          s << "Git branch: #{@git_branch.empty? ? "(none)" : @git_branch}\n"
        end
        @messages << Message.new("system", settings.strip)
      end

      # Mirrors TS `handleInitCommand` → `session.init()`: defer any user
      # messages typed during the run, then send the AGENTS.md generation
      # prompt as a regular turn. The agent walks the repo (Bash, Read, Glob)
      # and writes AGENTS.md to the project root.
      private def cmd_init : Nil
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
      end

      # Mirrors TS `handleExportDebugZipCommand`: bundle the session records
      # (wire.jsonl, state.json), a small manifest (version / provider /
      # model / timestamps), and the global log into a tar.gz the user can
      # share for debugging. Falls back to printing the session dir path if
      # tar is unavailable.
      private def cmd_export_debug_zip : Nil
        path = export_debug_bundle
        if path
          @messages << Message.new("system", "Debug bundle exported to: #{path}")
        else
          @messages << Message.new("error", "Failed to export debug bundle (tar not available?).")
        end
      end

      # Mirrors TS `showExperimentsPanel`: enumerate experimental flags and
      # their current state. hcode has no registry yet — flags are env-driven
      # (HCODE_EXPERIMENTAL_<NAME>) plus the master switch
      # HCODE_EXPERIMENTAL_FLAG=1. Surface the env so the user knows what is
      # on.
      private def cmd_experiments : Nil
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
      end

      # Subcommands: /mcp status, /mcp update [server], /mcp configure.
      # Bare /mcp defaults to status.
      private def cmd_mcp(args : String) : Nil
        sub = args.strip.split(/\s+/).reject(&.empty?)
        case sub[0]?
        when "update"
          server = sub[1]?
          msg = server ? "Refreshing MCP server '#{server}'..." : "Refreshing all MCP servers..."
          @messages << Message.new("system", msg)
          if cb = @on_mcp_update
            cb.call(server)
          else
            @messages << Message.new("error", "MCP update not available in this run.")
          end
        when "configure"
          @messages << Message.new("system", "MCP configuration: edit ~/.hcode/mcp.json directly, then run /mcp update to refresh the cache.")
        when "help"
          @messages << Message.new("system", MCP_HELP_TEXT)
        else
          # Default: show status.
          status = @on_mcp_status.try(&.call) ||
                   "MCP servers: not available in this run (no client wired)."
          @messages << Message.new("system", status)
        end
      end

      private def cmd_login : Nil
        if cb = @on_login
          @messages << Message.new("system", "Starting OAuth device-code login...")
          cb.call
        else
          cfg_path = File.join(@home, ".hcode", "config.json")
          cred_path = File.join(@home, ".kimi-code", "credentials", "kimi-code.json")
          body = String.build do |s|
            s << "Interactive login is not available in this build.\n\n"
            s << "Manual authentication options:\n"
            s << "  1. API key in config.json:\n"
            s << "       [provider.moonshot]\n"
            s << "       api_key = \"sk-...\"\n"
            s << "     Path: #{cfg_path}\n"
            s << "  2. OAuth credentials (JSON from kimi-code TS login):\n"
            s << "       #{cred_path}\n"
          end
          @messages << Message.new("system", body.strip)
        end
      end

      private def cmd_logout : Nil
        if cb = @on_logout
          cb.call
          @messages << Message.new("system", "Logged out. API key cleared from config.")
        else
          @messages << Message.new("error", "Logout is not wired up.")
        end
      end

      # `/init` — mirrors TS `DEFAULT_INIT_PROMPT`
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

      private def cmd_memory : Nil
        @messages << Message.new("system", ProfiledMemory.format_report)
      end
    end
  end
end
