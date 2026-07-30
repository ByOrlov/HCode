require "json"
require "http/client"
require "uri"
require "file"
require "file_utils"
require "dir"
require "io"
require "regex"
require "time"
require "random/secure"
require "system"
require "colorize"

require "./version"
require "./llm/types"
require "./llm/token_counter"
require "./llm/http_transport"
require "./llm/provider"
require "./llm/openai_chat_provider"
require "./llm/moonshot_provider"
require "./auth/oauth"
require "./llm/zai_provider"
require "./llm/ollama_provider"
require "./llm/lmstudio_provider"
require "./llm/mock_provider"
require "./tools/tool"
require "./tools/registry"
require "./tools/line_endings"
require "./tools/sensitive"
require "./tools/path_access"
require "./tools/run_rg"
require "./tools/bash"
require "./tools/read"
require "./tools/write"
require "./tools/edit"
require "./tools/glob"
require "./tools/grep"
require "./tools/todo_list"
require "./tools/agent_swarm"
require "./tools/agent"
require "./tools/ask_user_question"
require "./tools/fetch_url"
require "./tools/web_search"
require "./tools/skill"
require "./tools/plan_mode"
require "./tools/goal"
require "./tools/task"
require "./tools/cron"
require "./tools/read_media"
require "./tools/select_tools"
require "./context/memory"
require "./context/budget"
require "./context/undo"
require "./context/overflow"
require "./context/compaction"
require "./loop/retry"
require "./profiled_memory"
require "./loop/events"
require "./loop/abort"
require "./loop/dedup"
require "./loop/agent"
require "./loop/subagent_registry"
require "./loop/subagent_agent_runner"
require "./loop/subagent_swarm_runner"
require "./permission/manager"
require "./notify/config"
require "./notify/status"
require "./notify/terminal"
require "./notify/player"
require "./notify/webhook"
require "./notify/dispatcher"
require "./config/config"
require "./hooks/engine"
require "./prompt/template"
require "./prompt/agents_md"
require "./prompt/system_prompt"
require "./session/store"
require "./session/index"
require "./session/lifecycle"
require "./setup/wizard"
require "./tui/terminal"
require "./tui/char_width"
require "./tui/theme"
require "./tui/input"
require "./tui/component"
require "./tui/text"
require "./tui/spinner"
require "./tui/editor"
require "./tui/markdown"
require "./tui/select_list"
require "./tui/commands"
require "./tui/help_panel"
require "./tui/question_dialog"
require "./tui/plan_review_dialog"
require "./tui/undo_dialog"
require "./tui/tasks_browser"
require "./tui/app"
require "./tui/diff"
require "./tui/usage_panel"

module Hcode
  # Headless print-mode palette, ported from the original Moonshot kimi-code
  # TUI dark theme (apps/kimi-code/src/tui/theme/colors.ts).
  C_SUCCESS = Colorize::ColorRGB.new(0x4E, 0xC8, 0x7E)
  C_ERROR   = Colorize::ColorRGB.new(0xE8, 0x54, 0x54)
  C_PRIMARY = Colorize::ColorRGB.new(0x4F, 0xA8, 0xFF)
  C_SHELL   = Colorize::ColorRGB.new(0xBD, 0x93, 0xF9)
  C_DIM     = Colorize::ColorRGB.new(0x88, 0x88, 0x88)
  C_MUTED   = Colorize::ColorRGB.new(0x6B, 0x6B, 0x6B)

  # Raised when a provider cannot be built from the current config (missing
  # credentials, unknown name, ...). At startup it is rescued and turned into
  # an exit; at runtime the /provider selector catches it to show an inline
  # error without leaving the TUI.
  class ProviderConfigError < Exception
  end

  class CLI
    # Set by `--ram`. When true, every tool_result event prints RSS + tool
    # name + result size to stderr so live memory growth can be observed
    # without a debugger (Crystal + Boehm GC is hard to attach to).
    class_property? ram_tracing : Bool = false

    # Read current process RSS in MB. Delegates to ProfiledMemory so the
    # profiler stays self-contained (no dependency back into the CLI module).
    def self.rss_mb : Float64
      ProfiledMemory.rss_mb
    end

    # Build an RSS log line for a finished tool call. Returns nil when --ram
    # is not in effect. The caller is responsible for routing it into the
    # normal message stream (stdout in headless mode, Event.info in TUI) so
    # it never smears the diff-rendered frame.
    @@ram_start_rss : Float64 = 0.0
    @@ram_initialised : Bool = false

    def self.ram_line(tool_name : String, result_bytes : Int32, is_error : Bool) : String?
      return nil unless ram_tracing?

      unless @@ram_initialised
        @@ram_start_rss = rss_mb
        @@ram_initialised = true
      end

      current = rss_mb
      delta = current - @@ram_start_rss
      tag = is_error ? "!" : " "
      sprintf("[ram%s] RSS=%6.1f MB  Δ=%+6.1f MB  %s  result=%.1f KB",
        tag, current, delta, tool_name, result_bytes / 1024.0)
    end

    def self.run(argv : Array(String)) : Nil
      prompt = nil
      tui_prompt = nil
      work_dir = Dir.current
      model = nil
      session_id = nil
      permission_mode = nil
      show_help = false
      show_version = false
      continue_session = false
      hi_mode = false

      i = 0
      while i < argv.size
        case argv[i]
        when "-p", "--prompt"
          i += 1
          prompt = argv[i]? || ""
        when "--tui-prompt"
          i += 1
          tui_prompt = argv[i]? || ""
        when "-d", "--work-dir"
          i += 1
          work_dir = argv[i]? || Dir.current
        when "-m", "--model"
          i += 1
          model = argv[i]
        when "-s", "--session"
          i += 1
          session_id = argv[i]
        when "-c", "--continue"
          continue_session = true
        when "--permission"
          i += 1
          permission_mode = argv[i]
        when "--yolo"
          permission_mode = "yolo"
        when "--auto"
          permission_mode = "auto"
        when "--hi"
          hi_mode = true
        when "--ram"
          CLI.ram_tracing = true
        when "-h", "--help"
          show_help = true
        when "-v", "--version"
          show_version = true
        end
        i += 1
      end

      if show_help
        print_usage
        return
      end

      if show_version
        puts "HCode #{VERSION}"
        return
      end

      config = Config::Config.load

      config.model = model if model
      if pm = permission_mode
        config.permission_mode = pm
      end
      config.ensure_hcode_home

      home = ENV["HOME"]? || "/tmp"

      oauth_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
      oauth = LLM::OAuthCredentials.load(oauth_path)

      # First-run gate: if no provider is configured yet, either run the
      # interactive setup wizard (TTY) or fail with a clear message (non-TTY).
      unless config.provider_name && config.provider_configured?
        if STDIN.tty? && !hi_mode && prompt.nil?
          run_setup_wizard(config)
        else
          STDERR.puts "Error: No provider configured."
          STDERR.puts ""
          STDERR.puts "Run `hcode` once in a terminal to set up interactively, or set:"
          STDERR.puts "  export HCODE_PROVIDER=ollama    # or: moonshot, zai, lmstudio"
          STDERR.puts "  export MOONSHOT_API_KEY=YOUR_KEY  # needed for moonshot/zai"
          STDERR.puts ""
          STDERR.puts "See `hcode --help` for details."
          exit(2)
        end
      end

      provider = build_provider(config, oauth)

      if hi_mode
        run_hi(provider)
        return
      end

      memory = Context::Memory.new
      memory.max_context_tokens = config.max_context_tokens

      tools = Tools::Registry.new
      tools.register(Tools::Bash.new(work_dir))
      tools.register(Tools::Read.new(work_dir))
      tools.register(Tools::Write.new(work_dir))
      tools.register(Tools::Edit.new(work_dir))
      tools.register(Tools::Glob.new(work_dir))
      tools.register(Tools::Grep.new(work_dir))
      tools.register(Tools::TodoList.new)
      tools.register(Tools::AgentSwarm.new)
      tools.register(Tools::Agent.new)
      tools.register(Tools::AskUserQuestion.new)
      tools.register(Tools::FetchURL.new)
      tools.register(Tools::WebSearch.new)
      tools.register(Tools::Skill.new)
      tools.register(Tools::EnterPlanMode.new)
      tools.register(Tools::ExitPlanMode.new)
      tools.register(Tools::CreateGoal.new)
      tools.register(Tools::GetGoal.new)
      tools.register(Tools::UpdateGoal.new)
      tools.register(Tools::SetGoalBudget.new)
      tools.register(Tools::TaskList.new)
      tools.register(Tools::TaskOutput.new)
      tools.register(Tools::TaskStop.new)
      tools.register(Tools::CronCreate.new)
      tools.register(Tools::CronList.new)
      tools.register(Tools::CronDelete.new)
      tools.register(Tools::ReadMediaFile.new)
      tools.register(Tools::SelectTools.new)

      permission = Permission::Manager.new(Permission::Mode.parse(config.permission_mode))

      home = ENV["HOME"]? || "/tmp"
      lifecycle = Hcode::Session::Lifecycle.new(home)
      store = if sid = session_id
                # Resolve across every workspace + legacy flat layout.
                entry = lifecycle.index.get(sid)
                if entry
                  Hcode::Session::Store.new(entry.path)
                else
                  # Fall back to the literal flat-layout path for ids the
                  # Index has not indexed yet (e.g. created mid-session).
                  Hcode::Session::Store.new(File.join(home, ".hcode", "sessions", sid))
                end
              elsif continue_session
                ws_id = Hcode::Session::Index.workspace_id(work_dir)
                entry = lifecycle.index.find_most_recent(ws_id) ||
                        lifecycle.index.find_most_recent
                unless entry
                  STDERR.puts "No previous session found to continue."
                  exit(1)
                end
                Hcode::Session::Store.new(entry.path)
              else
                lifecycle.create(work_dir)
              end

      if continue_session || session_id
        store.replay(memory)
      end

      # Bind the session to the provider so the backend caches the prompt
      # prefix keyed by the session id — without this every step reprocesses
      # the full growing context from scratch.
      sid_for_cache = (store.read_state.try(&.id) || store.meta_id? || session_id || Random::Secure.hex(12))
      configure_provider(provider, config, sid_for_cache)

      agent = Loop::Agent.new(provider, memory, tools, permission)
      agent.hooks = Hooks::Engine.new(config.hooks, cwd: work_dir, session_id: store.meta_id?) unless config.hooks.empty?

      # Discover skills from disk (user home + project root) and register them
      # in the global catalog so the Skill tool can resolve them.
      discovered = Hcode::Tools::SkillDiscovery.discover(home, work_dir)
      skill_catalog = Hcode::Tools::InMemorySkillCatalog.new(discovered)
      Hcode::Tools::Skill.catalog = skill_catalog
      Hcode::Tools::Skill.memory = memory

      system_prompt = Prompt::SystemPrompt.build(work_dir,
        additional_dirs: [] of String,
        skills_listing: skill_catalog.model_listing)

      task_service = Hcode::Tools::InMemoryTaskService.new
      Hcode::Tools::Task.service = task_service

      goal_service = Hcode::Tools::AgentGoalService.new
      Hcode::Tools::Goal.service = goal_service
      wire_subagent_runners(agent, task_service, system_prompt, work_dir, config)

      if prompt
        run_headless(prompt, agent, system_prompt, store, config)
      else
        run_interactive(agent, system_prompt, store, config, permission, oauth, home, work_dir, tui_prompt)
      end
    end

    # Startup entry: build the configured provider, exiting the process with a
    # clear message if config is incomplete.
    private def self.build_provider(config, oauth) : LLM::Provider
      build_named_provider(config.provider_name, config, oauth)
    rescue ex : ProviderConfigError
      STDERR.puts "Error: #{ex.message}"
      exit(1)
    end

    # Build a provider by name from the current config. Raises
    # ProviderConfigError on missing credentials or an unknown name, so callers
    # that must not exit (e.g. the /provider selector at runtime) can rescue
    # and surface the message instead.
    def self.build_named_provider(name : String?, config, oauth) : LLM::Provider
      if name.nil? || name.empty?
        available = LLM::KNOWN_PROVIDERS.map(&.name).join(", ")
        raise ProviderConfigError.new("No provider configured. Available: #{available}")
      end
      case name
      when "moonshot"
        if oauth.nil? && config.api_key.to_s.empty?
          raise ProviderConfigError.new(
            "No Moonshot credentials found. Either:\n" \
            "  1. Login with Moonshot's kimi-code CLI (creates ~/.kimi-code/credentials/kimi-code.json)\n" \
            "  2. Set MOONSHOT_API_KEY environment variable")
        end
        LLM::MoonshotProvider.new(
          model: config.model || "kimi-for-coding",
          endpoint: config.endpoint || LLM::MoonshotProvider::DEFAULT_ENDPOINT,
          oauth: oauth,
          api_key: config.api_key.to_s,
          temperature: config.temperature,
        )
      when "zai"
        if config.zai_api_key.empty?
          raise ProviderConfigError.new(
            "No Z.AI credentials found. Set the ZAI_API_KEY or ZHIPU_API_KEY environment variable " \
            "(or [provider.zai] api_key in config).")
        end
        LLM::ZaiProvider.new(
          model: config.zai_model,
          endpoint: config.zai_endpoint,
          api_key: config.zai_api_key,
          provider_label: "zai",
        )
      when "zai-coding-plan"
        if config.zai_api_key.empty?
          raise ProviderConfigError.new(
            "No Z.AI credentials found. Set the ZAI_API_KEY or ZHIPU_API_KEY environment variable.")
        end
        LLM::ZaiProvider.new(
          model: config.zai_coding_plan_model,
          endpoint: config.zai_coding_plan_endpoint,
          api_key: config.zai_api_key,
          provider_label: "zai-coding-plan",
        )
      when "ollama"
        endpoint = config.ollama_endpoint || LLM::OllamaProvider::DEFAULT_ENDPOINT
        LLM::OllamaProvider.new(
          model: config.ollama_model || LLM::OllamaProvider::DEFAULT_MODEL,
          endpoint: endpoint,
        )
      when "lmstudio"
        endpoint = config.lmstudio_endpoint || LLM::LmStudioProvider::DEFAULT_ENDPOINT
        LLM::LmStudioProvider.new(
          model: config.lmstudio_model || LLM::LmStudioProvider::DEFAULT_MODEL,
          endpoint: endpoint,
        )
      when "mock"
        LLM::MockProvider.new(LLM::MockProvider.script_from_env || LLM::MockProvider::DEFAULT_SCRIPT.dup)
      else
        available = LLM::KNOWN_PROVIDERS.map(&.name).join(", ")
        raise ProviderConfigError.new("Unknown provider '#{name}'. Available: #{available}")
      end
    end

    # Fold the runtime request-config into a freshly built provider: the
    # session prompt-cache key (so the backend caches the prompt prefix across
    # steps), the configured thinking effort, and the model context window
    # (used to clamp the per-step completion budget). The setters are no-ops on
    # providers that don't override them (e.g. Mock), so this is safe to call
    # uniformly on any backend.
    def self.configure_provider(provider, config, cache_key : String?) : Nil
      provider.thinking_effort = config.thinking_effort
      provider.max_context_tokens = config.max_context_tokens
      provider.prompt_cache_key = cache_key
    end

    # Smoke test: send "hi" to the configured provider and report the
    # result. No tools, no system prompt, no agent loop — just a raw
    # chat call to verify the key, endpoint, model, and balance.
    private def self.run_hi(provider : LLM::Provider) : Nil
      puts "Provider: #{provider.name}"
      puts "Model:    #{provider.model_name}"
      puts "Prompt:   \"hi\""
      puts "────────────────────────────────────────"

      messages = [LLM::Message.user("hi")]
      text = IO::Memory.new

      begin
        result = provider.chat(messages, nil) do |part|
          case part
          when LLM::TextPart
            print part.text.colorize.fore(C_DIM)
            STDOUT.flush
            text << part.text
          end
        end

        puts ""
        puts ""
        puts "● OK — replied in #{result.usage.total_tokens} tokens"
          .colorize.fore(C_SUCCESS)
        exit(0)
      rescue ex : LLM::ApiError
        STDERR.puts ""
        STDERR.puts "✗ HTTP #{ex.status_code}: #{ex.message}"
          .colorize.fore(C_ERROR)
        exit(1)
      rescue ex
        STDERR.puts ""
        STDERR.puts "✗ #{ex.message}".colorize.fore(C_ERROR)
        exit(1)
      end
    end

    private def self.wire_subagent_runners(agent : Loop::Agent,
                                           task_service : Tools::InMemoryTaskService,
                                           system_prompt : String,
                                           work_dir : String,
                                           config : Config::Config) : Nil
      registry = Loop::SubagentRegistry.new
      permission_mode = Permission::Mode.parse(config.permission_mode)

      agent_runner = Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: agent,
        task_service: task_service,
        system_prompt: system_prompt,
        work_dir: work_dir,
        permission_mode: permission_mode,
      )
      swarm_runner = Loop::SubagentSwarmRunner.new(
        registry: registry,
        parent_agent: agent,
        system_prompt: system_prompt,
        work_dir: work_dir,
        permission_mode: permission_mode,
      )
      Tools::Agent.runner = agent_runner
      Tools::AgentSwarm.runner = swarm_runner
      # TaskList/TaskOutput/TaskStop are registered for the main agent, so
      # background subagent execution is available.
      Tools::Agent.background_enabled = true
    end

    private def self.run_headless(prompt, agent, system_prompt, store, config)
      store.append_simple("turn.prompt", "prompt", prompt)

      Signal::INT.trap do
        STDERR.puts "\nInterrupted."
        agent.cancel
      end

      # Headless dispatcher: useful for CI/automation webhooks. StatusTracker
      # drives Working→Done around the single turn.
      dispatcher = Notify::Dispatcher.from_config(config.notifications)
      status_tracker = Notify::StatusTracker.new { |t| dispatcher.on_transition(t) }
      status_tracker.transition!(Notify::AgentStatus::Working)

      assistant_buf = IO::Memory.new
      assistant_open = false
      thinking_open = false
      pending_calls = {} of String => {String, String}

      begin
        result = agent.run_turn(prompt, system_prompt) do |event|
          case event.type
          when .step_begin?
            assistant_buf.clear
          when .thinking_delta?
            unless thinking_open
              puts
              thinking_open = true
            end
            print event.text.colorize.fore(:light_gray).dim
            STDOUT.flush
          when .text_delta?
            if thinking_open
              puts
              puts
              thinking_open = false
            end
            unless assistant_open
              print " ● ".colorize.fore(:light_gray).dim
              assistant_open = true
            end
            assistant_buf << event.text
            print event.text.colorize.fore(:light_gray).dim
            STDOUT.flush
          when .assistant_text?
            store.append("assistant.text", {"content" => JSON::Any.new(assistant_buf.to_s)})
            if assistant_open
              puts
              puts
              assistant_open = false
            end
          when .tool_call_start?
            store.append("tool.call", {
              "tool_call_id" => JSON::Any.new(event.tool_call_id),
              "tool_name"    => JSON::Any.new(event.tool_name),
              "arguments"    => JSON::Any.new(event.tool_args),
            })
            pending_calls[event.tool_call_id] = {event.tool_name, event.tool_args}
          when .tool_result?
            store.append("tool.result", {
              "tool_call_id" => JSON::Any.new(event.tool_call_id),
              "content"      => JSON::Any.new(event.text),
            })
            if assistant_open
              puts
              puts
              assistant_open = false
            end
            name, args = pending_calls.delete(event.tool_call_id) || {"Tool", ""}
            render_tool_block(name, args, event.text, event.is_error)
            if line = CLI.ram_line(name, event.text.bytesize, event.is_error)
              puts line.colorize.yellow
            end
          when .info?
            puts "[#{event.text}]".colorize.yellow
          when .error?
            STDERR.puts "Error: #{event.text}".colorize.red
          end
        end

        puts
        puts "● Done (#{result.steps} steps, " \
             "#{result.usage.total_tokens} tokens)".colorize.fore(C_SUCCESS)
        puts
        status_tracker.transition!(Notify::AgentStatus::Done, "Turn complete")
        status_tracker.transition!(Notify::AgentStatus::Idle)
      rescue ex : Loop::UserCancellationError
        agent.context.add_user("Interrupted by user")
        puts "\nInterrupted by user.".colorize.yellow
        status_tracker.transition!(Notify::AgentStatus::Done, "Cancelled")
        status_tracker.transition!(Notify::AgentStatus::Idle)
      rescue ex : Loop::NetworkFailureError
        puts "\n#{ex.message}".colorize.yellow
        status_tracker.transition!(Notify::AgentStatus::Done, "Network failure")
        status_tracker.transition!(Notify::AgentStatus::Idle)
      rescue ex
        STDERR.puts "Fatal: #{ex.message}".colorize.red
        ex.backtrace.each { |b| STDERR.puts "  #{b}" } if ENV["HCODE_DEBUG"]?
        exit(1)
      end
    end

    # Run the interactive setup wizard inside a minimal TUI. The wizard collects
    # the provider choice and credentials, writes them to config.toml, then
    # returns so the caller can build the real provider and proceed.
    private def self.run_setup_wizard(config) : Nil
      app = TUI::App.new
      app.start_setup
      app.on_setup_complete = ->(wizard : Setup::Wizard) do
        wizard.apply_to(config)
        config.save
        app.provider_name = wizard.provider_name.to_s
        app.model = wizard.model.to_s
        nil
      end

      # The wizard runs in a closed TUI loop without an agent. On completion
      # the on_setup_complete callback fires; we exit the loop by toggling
      # the running flag indirectly via the app's setup_mode.
      spawn do
        # Wait for setup to finish, then stop the loop.
        while app.setup_mode?
          Fiber.yield
        end
        app.stop
      end

      app.run { |_text, _persisted| }
    end

    private def self.run_interactive(agent, system_prompt, store, config, permission, oauth, home, work_dir, initial_prompt = nil)
      dispatcher = Notify::Dispatcher.from_config(config.notifications)
      app = TUI::App.new(dispatcher: dispatcher)
      app.model = agent.provider.model_name
      app.provider_name = config.provider_name.to_s
      app.permission_mode = config.permission_mode
      app.max_context_tokens = agent.context.max_context_tokens
      app.home = home
      app.work_dir = work_dir

      lifecycle = Session::Lifecycle.new(home)

      # `/add-dir` rebuilds the system prompt so the new directory appears in
      # the workspace tree and the agent knows about it. `system_prompt` is the
      # method argument captured by the `app.run` block below; reassigning it
      # here updates what every subsequent turn sees.
      app.on_additional_dirs_change = ->(dirs : Array(String)) do
        catalog = Hcode::Tools::Skill.catalog
        listing = catalog.is_a?(Hcode::Tools::InMemorySkillCatalog) ? catalog.model_listing : ""
        system_prompt = Prompt::SystemPrompt.build(work_dir, dirs, listing)
        nil
      end

      permission.approval_callback = ->(tool_name : String, args : String, danger : String?) do
        app.request_approval(tool_name, args, danger)
      end

      # Wire the AskUserQuestion tool to the TUI's structured question dialog.
      # When the agent calls AskUserQuestion, the QuestionService implementation
      # pushes the questions into the App's dialog and blocks until the user
      # answers. Mirrors TS `reverse-rpc/question-adapter.ts`.
      Hcode::Tools::AskUserQuestion.service = AppQuestionService.new(app)

      # Plan-mode wiring: instantiate the per-session plan service, expose its
      # permission mode, and bridge ExitPlanMode's interactive review to the
      # TUI's PlanReviewDialog. `/plan` toggles the mode through on_plan_mode.
      plan_service = Hcode::Tools::AgentPlanService.new(store.session_dir, "main")
      Hcode::Tools::PlanMode.plan_service = plan_service
      Hcode::Tools::PlanMode.permission_mode = Hcode::Tools::PermissionModeRef.new(
        auto: permission.mode.auto?)
      Hcode::Tools::PlanMode.plan_review_service = AppPlanReviewService.new(app)
      app.on_plan_mode = ->(next_on : Bool) do
        svc = Hcode::Tools::PlanMode.plan_service
        false if svc.nil?
        begin
          if next_on
            svc.try(&.enter)
          else
            svc.try(&.cancel)
          end
          true
        rescue
          false
        end
      end

      # TaskService was already created and assigned in `run` so the headless
      # path shares the same instance; reuse it here for the profilers and the
      # /tasks browser.
      task_service = Hcode::Tools::Task.service.as(Hcode::Tools::InMemoryTaskService)

      register_profilers(agent, app, permission, task_service, system_prompt)

      app.on_clear = ->{ agent.context.clear }
      app.on_undo = ->{ agent.context.undo(1) }
      app.on_cancel = ->{ agent.cancel }
      app.on_undo_count = ->(count : Int32) do
        agent.context.undo(count)
        nil
      end
      # Build the undo-selector candidate list from user messages in the
      # agent's history. Each choice represents "remove N turns down to
      # and including this user turn".
      app.on_fetch_undo_choices = -> : Array({Int32, String, String})? do
        history = agent.context.history
        choices = [] of {Int32, String, String}
        # Walk history; each user message marks a turn boundary. The count
        # for entry i = messages to drop from the end back to and including
        # that user message.
        history.each_with_index do |cm, idx|
          next unless cm.message.role == "user" && cm.origin.normal?
          input = cm.message.content.to_s
          preview = input.empty? ? "(empty)" : input[0...60].gsub('\n', " ")
          count = history.size - idx
          choices << {count, input, "##{idx + 1}: #{preview}"}
        end
        choices.empty? ? nil : choices
      end
      app.on_compact = -> : Nil do
        spawn do
          agent.trigger_compaction_tui(system_prompt) do |event|
            app.on_event(event)
          end
        end
      end
      app.on_new_session = ->{
        agent.context.clear
        new_store = lifecycle.create(work_dir)
        store.session_dir = new_store.session_dir
        store.wire_path = new_store.wire_path
        store.state_path = new_store.state_path
        store.ensure_wire
        app.session_id = store.read_state.try(&.id) || ""
        Hcode::Tools::PlanMode.plan_service = Hcode::Tools::AgentPlanService.new(store.session_dir, "main")
        nil
      }
      app.on_resume_session = ->(path : String) do
        resumed = Session::Store.new(path)
        agent.context.clear
        resumed.replay(agent.context)
        store.session_dir = resumed.session_dir
        store.wire_path = resumed.wire_path
        store.state_path = resumed.state_path
        app.session_id = resumed.read_state.try(&.id) || resumed.meta_id? || ""
        app.load_transcript_from(agent.context)
        Hcode::Tools::PlanMode.plan_service = Hcode::Tools::AgentPlanService.new(store.session_dir, "main")
        nil
      end
      app.on_fork = ->{
        forked = lifecycle.fork(store, work_dir)
        store.session_dir = forked.session_dir
        store.wire_path = forked.wire_path
        store.state_path = forked.state_path
        app.session_id = forked.read_state.try(&.id) || ""
        nil
      }
      app.on_archive = ->{
        id = store.read_state.try(&.id) || store.meta_id? || File.basename(store.session_dir)
        lifecycle.archive(id)
      }
      app.on_rename = ->(title : String) do
        id = store.read_state.try(&.id) || store.meta_id? || File.basename(store.session_dir)
        entry = lifecycle.index.get(id)
        if entry
          lifecycle.rename(entry, title)
        else
          # Fallback: write state directly when the index has not indexed it yet.
          meta = store.read_state || Session::StateMeta.new(id)
          meta.title = title
          store.write_state(meta)
        end
      end
      app.on_export = ->(path : String) {
        export_session(agent.context, path)
      }
      app.on_provider_change = ->(name : String) : Bool do
        begin
          provider = build_named_provider(name, config, oauth)
          configure_provider(provider, config, store.meta_id?)
          agent.swap_provider!(provider)
          config.provider_name = name
          config.save
          app.model = provider.model_name
          true
        rescue ex : ProviderConfigError
          app.add_message("error", "Failed to switch provider: #{ex.message}")
          false
        rescue ex
          app.add_message("error", "Failed to switch provider: #{ex.message}")
          false
        end
      end

      app.on_model_change = ->(model : String) : Bool do
        begin
          case config.provider_name
          when "moonshot"
            config.model = model
          when "zai"
            config.zai_model = model
          when "zai-coding-plan"
            config.zai_coding_plan_model = model
          when "ollama"
            config.ollama_model = model
          when "lmstudio"
            config.lmstudio_model = model
          end
          provider = build_named_provider(config.provider_name, config, oauth)
          configure_provider(provider, config, store.meta_id?)
          agent.swap_provider!(provider)
          config.save
          true
        rescue ex : ProviderConfigError
          app.add_message("error", "Failed to switch model: #{ex.message}")
          false
        rescue ex
          app.add_message("error", "Failed to switch model: #{ex.message}")
          false
        end
      end

      app.on_fetch_models = -> : Array(String) do
        agent.provider.fetch_models
      end

      # Expose the TodoList tool's state to the TUI so it can render a
      # progress panel above the editor. Returns nil if the tool isn't
      # registered (no TodoList in this agent) or the list is empty.
      app.on_fetch_todos = -> : Array({String, String})? do
        todo_tool = agent.tools.get("TodoList")
        return nil unless t = todo_tool.as?(Hcode::Tools::TodoList)
        todos = t.todos
        return nil if todos.empty?
        todos.map { |todo| {todo.title, todo.status.to_s.downcase} }
      end
      app.on_clear_todos = -> : Nil do
        todo_tool = agent.tools.get("TodoList")
        return nil unless t = todo_tool.as?(Hcode::Tools::TodoList)
        t.todos.clear
        nil
      end

      # `/export-debug-zip` reads wire.jsonl/state.json from the session dir.
      app.on_session_dir = -> : String? do
        dir = store.session_dir
        dir.empty? ? nil : dir
      end

      # `/tasks` browser: pull the current task list from the service,
      # stop a task, open its full output.
      app.on_fetch_tasks = -> : Array(Hcode::Tools::AgentTaskInfo) do
        task_service.list(active_only: false, limit: 100)
      end
      app.on_stop_task = ->(task_id : String) do
        task_service.stop_by_user(task_id)
        nil
      end
      app.on_open_task_output = ->(task_id : String) do
        snapshot = task_service.get_output_snapshot(task_id, 8192)
        preview = snapshot.preview
        # Surface the output inline as a system message so the user can read
        # it without leaving the transcript.
        app.add_message("system", "Output of #{task_id}:\n#{preview}")
        nil
      end
      # `/logout` clears the configured API keys and re-saves config.toml.
      app.on_logout = -> : Nil do
        config.api_key = ""
        config.zai_api_key = ""
        config.save
        nil
      end

      login_cb = Proc(Nil).new do
        spawn do
          begin
            cred_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
            creds = Auth::OAuth.login(credentials_path: cred_path) do |auth|
              app.on_event(Loop::Event.info("Open this URL to authorize: #{auth.verification_uri_complete}"))
              app.on_event(Loop::Event.info("User code: #{auth.user_code}"))
            end
            # Rebuild the provider with fresh credentials so the next turn uses
            # them without a restart.
            provider = LLM::MoonshotProvider.new(
              model: config.model || "kimi-for-coding",
              endpoint: config.endpoint || LLM::MoonshotProvider::DEFAULT_ENDPOINT,
              oauth: creds,
              api_key: "",
              temperature: config.temperature,
            )
            agent.swap_provider!(provider)
            app.on_event(Loop::Event.info("Login successful. Credentials saved to #{cred_path}"))
          rescue ex : Auth::OAuth::OAuthError
            app.on_event(Loop::Event.error("Login failed: #{ex.message}"))
          rescue ex
            app.on_event(Loop::Event.error("Login error: #{ex.message}"))
          end
        end
      end
      app.on_login = login_cb

      # Thinking-effort selector (off/low/medium/high/...). Backed by the
      # provider's `thinking_effort` property; setting it persists into the
      # next chat request via `build_request`.
      app.on_get_effort = -> : String do
        agent.provider.thinking_effort || "off"
      end
      app.on_set_effort = ->(effort : String) do
        normalized = case effort.downcase
                     when "off", "none", "0" then nil
                     else                         effort.downcase
                     end
        agent.provider.thinking_effort = normalized
        nil
      end

      # Steer: inject the text into the running turn's context so the model
      # sees it on its next step. Mirrors `session.steer(text)` in TS.
      app.on_steer = ->(text : String) do
        agent.steer(text)
        nil
      end

      # Persist queued / steered messages to the wire log so the queue
      # survives a resume. Wire type distinguishes the two flows.
      app.on_persist_queued = ->(wire_type : String, text : String) do
        store.append_simple(wire_type, "prompt", text)
        nil
      end

      app.on_debug = -> : Nil do
        app.restore_terminal
        render_debug_transcript(store)
        exit(0)
      end

      app.session_id = store.meta_id? || ""

      app.run(initial_prompt: initial_prompt) do |prompt_text, persisted|
        store.append_simple("turn.prompt", "prompt", prompt_text) unless persisted

        # tool_call_id → tool_name, populated by tool_call_start and consumed
        # by tool_result so the --ram log can show which tool ran. Lives one
        # turn at a time; cleared at turn end.
        pending_tool_names = {} of String => String

        begin
          result = agent.run_turn(prompt_text, system_prompt) do |event|
            case event.type
            when .text_delta?
              app.on_event(Loop::Event.text_delta(event.text))
            when .thinking_delta?
              app.on_event(event)
            when .assistant_text?
              store.append("assistant.text", {"content" => JSON::Any.new(event.text)})
              app.on_event(event)
            when .tool_call_start?
              store.append("tool.call", {
                "tool_call_id" => JSON::Any.new(event.tool_call_id),
                "tool_name"    => JSON::Any.new(event.tool_name),
                "arguments"    => JSON::Any.new(event.tool_args),
              })
              pending_tool_names[event.tool_call_id] = event.tool_name
              app.on_event(event)
            when .tool_result?
              store.append("tool.result", {
                "tool_call_id" => JSON::Any.new(event.tool_call_id),
                "content"      => JSON::Any.new(event.text),
              })
              # Resolve tool name from the event itself (Event.tool_result
              # does not carry it; the prior tool_call_start had it).
              tname = pending_tool_names.delete(event.tool_call_id) || "Tool"
              # Attach the RAM line so the TUI renders it inside the tool
              # block rather than as a separate info message.
              event.ram_line = CLI.ram_line(tname, event.text.bytesize, event.is_error)
              app.on_event(event)
            when .step_begin?, .step_end?, .info?, .error?, .turn_end?,
                 .compaction_started?, .compaction_completed?, .compaction_cancelled?
              app.on_event(event)
              app.context_percent = agent.context.token_usage_percent
              app.context_tokens = agent.context.token_count
            end
          end

          app.context_percent = agent.context.token_usage_percent
          app.context_tokens = agent.context.token_count
        rescue ex : Loop::UserCancellationError
          agent.context.add_user("Interrupted by user")
          app.show_interrupted
        rescue ex : Loop::NetworkFailureError
          app.show_interrupted(ex.message.to_s)
        rescue ex
          app.on_event(Loop::Event.error(ex.message.to_s))
        end
      end
    end

    # Register the long-lived growing collections with the memory profiler.
    # Each closure captures an owner that is already alive for the whole
    # process, so no extra GC pressure is introduced. `/memory` walks these
    # on demand to report current consumption.
    private def self.register_profilers(agent : Loop::Agent, app : TUI::App,
                                        permission : Permission::Manager,
                                        task_service : Tools::InMemoryTaskService,
                                        system_prompt : String) : Nil
      ctx_mem = agent.context
      perm_mgr = permission
      dedup = agent.dedup
      tools = agent.tools
      ProfiledMemory.register("context:history", "context history",
        calc: ->{ ctx_mem.profiled_bytes }, count: ->{ ctx_mem.profiled_count })
      ProfiledMemory.register("tui:messages", "TUI transcript",
        calc: ->{ app.profiled_bytes }, count: ->{ app.profiled_count })
      ProfiledMemory.register("tui:render_buf", "render buffer",
        calc: ->{ app.render_buffer_bytes }, count: ->{ app.render_buffer_count })
      ProfiledMemory.register("tui:queue", "queued messages",
        calc: ->{ app.queue_bytes }, count: ->{ app.queue_count })
      ProfiledMemory.register("perm:approvals", "session approvals",
        calc: ->{ perm_mgr.profiled_bytes }, count: ->{ perm_mgr.profiled_count })
      ProfiledMemory.register("tasks", "background tasks",
        calc: ->{ task_service.profiled_bytes }, count: ->{ task_service.profiled_count })
      ProfiledMemory.register("dedup:history", "dedup tracker",
        calc: ->{ dedup.profiled_bytes }, count: ->{ dedup.profiled_count })
      ProfiledMemory.register("tools:registry", "tool registry",
        calc: ->{ tools.profiled_bytes }, count: ->{ tools.profiled_count })
      ProfiledMemory.register("tui:width_cache", "width cache",
        calc: ->{ TUI::CharWidth.cache_bytes }, count: ->{ TUI::CharWidth.cache_count })
      unless system_prompt.empty?
        sp = system_prompt
        ProfiledMemory.register("system_prompt", "system prompt",
          calc: ->{ sp.profiled_bytes })
      end
      todo_tool = tools.get("TodoList")
      register_todo_profiler(todo_tool) if todo_tool.is_a?(Tools::TodoList)
      register_cron_profiler
      register_skill_profiler
    end

    private def self.register_todo_profiler(todo : Tools::TodoList) : Nil
      ProfiledMemory.register("todos", "todo list",
        calc: ->{ todo.profiled_bytes },
        count: ->{ todo.profiled_count })
    end

    private def self.register_cron_profiler : Nil
      service = Tools::Cron.service
      return unless service.is_a?(Tools::InMemoryCronService)
      ProfiledMemory.register("cron:tasks", "cron tasks",
        calc: ->{ service.profiled_bytes },
        count: ->{ service.profiled_count })
    end

    private def self.register_skill_profiler : Nil
      catalog = Tools::Skill.catalog
      return unless catalog.is_a?(Tools::InMemorySkillCatalog)
      ProfiledMemory.register("skills:catalog", "skill catalog",
        calc: ->{ catalog.profiled_bytes },
        count: ->{ catalog.profiled_count })
    end

    private def self.export_session(memory, path : String) : Nil
      content = String.build do |s|
        s << "# Session Export\n\n"
        memory.messages.each do |msg|
          case msg.role
          when "user"
            s << "## User\n\n#{msg.content}\n\n"
          when "assistant"
            s << "## Assistant\n\n#{msg.content}\n\n"
          when "tool"
            s << "### Tool: #{msg.tool_calls.try(&.first).try(&.name) || "??"}\n\n"
            s << "```\n#{msg.content}\n```\n\n"
          end
        end
      end
      File.write(path, content)
    end

    private def self.render_tool_block(name : String, args : String, output : String, is_error : Bool) : Nil
      display = output
      exit_code = -1
      # Bash embeds a non-zero exit as "[exit code: N]"; lift it out so we can
      # render it as a dedicated red footer instead of raw text.
      if m = display.match(/(?:\n)?\[exit code: (\d+)\]\s*\z/)
        exit_code = m[1]?.try(&.to_i?) || -1
        display = display.sub(/(?:\n)?\[exit code: \d+\]\s*\z/, "")
      end
      failed = is_error || exit_code > 0

      marker = failed ? "✗".colorize.fore(C_ERROR) : "●".colorize.fore(C_SUCCESS)
      label_c = failed ? C_ERROR : C_PRIMARY
      header = name == "Bash" ? "Ran a command" : name
      puts " #{marker} #{header.colorize.fore(label_c).bold}"

      parsed = args.empty? ? nil : begin
        JSON.parse(args)
      rescue JSON::ParseException
        nil
      end
      echo_tool_args(name, parsed)

      trimmed = display.strip
      unless trimmed.empty?
        out_c = failed ? C_ERROR : C_MUTED
        trimmed.each_line do |line|
          puts "   #{line.colorize.fore(out_c)}"
        end
      end

      if failed
        msg = exit_code > 0 ? "   Command failed with exit code: #{exit_code}." : "   Command failed."
        puts msg.colorize.fore(C_ERROR)
      end
      puts
    end

    private def self.render_debug_transcript(store) : Nil
      events = store.read_events
      puts "=== Debug transcript: #{store.session_dir} ==="
      puts

      pending_calls = {} of String => {String, String}

      events.each do |event|
        case event[:type]
        when "turn.prompt", "turn.steer"
          if prompt = event[:data]["prompt"]?.try(&.as_s?)
            puts "User: #{prompt}"
            puts
          end
        when "assistant.text"
          if content = event[:data]["content"]?.try(&.as_s?)
            puts content
            puts
          end
        when "tool.call"
          id = event[:data]["tool_call_id"]?.try(&.as_s?) || ""
          name = event[:data]["tool_name"]?.try(&.as_s?) || "Tool"
          args = event[:data]["arguments"]?.try(&.as_s?) || "{}"
          pending_calls[id] = {name, args}
        when "tool.result"
          id = event[:data]["tool_call_id"]?.try(&.as_s?) || ""
          content = event[:data]["content"]?.try(&.as_s?) || ""
          name, args = pending_calls.delete(id) || {"Tool", ""}
          render_tool_block(name, args, content, false)
        end
      end
    end

    private def self.echo_tool_args(name : String, parsed : JSON::Any?) : Nil
      return if parsed.nil?
      case name
      when "Bash"
        if cmd = parsed["command"]?.try(&.as_s?)
          puts "   #{"$ ".colorize.fore(C_SHELL)}#{cmd.colorize.fore(C_DIM).dim}"
        end
      when "Read", "Write", "Edit"
        if path = (parsed["path"]? || parsed["filePath"]?).try(&.as_s?)
          puts "   file: #{path}".colorize.fore(C_DIM).dim
        end
      when "Glob"
        if pat = parsed["pattern"]?.try(&.as_s?)
          puts "   pattern: #{pat}".colorize.fore(C_DIM).dim
        end
      when "Grep"
        if pat = parsed["pattern"]?.try(&.as_s?)
          puts "   search: #{pat}".colorize.fore(C_DIM).dim
        end
      end
    end

    private def self.print_usage : Nil
      puts <<-USAGE
        HCode #{VERSION} — lighter than air AI agent

        Usage:
          hcode -p "your prompt here" [options]

        Options:
          -p, --prompt <text>     Prompt to send to the agent
          -d, --work-dir <path>   Working directory (default: current)
          -c, --continue          Resume the most recent session
          -m, --model <name>      Model name (default: kimi-for-coding)
          -s, --session <id>      Resume session by ID
          --permission <mode>     manual | auto | yolo
          --yolo                  Auto-approve all tool calls
          --auto                  Auto-approve safe operations
          --hi                    Smoke test: send "hi" to the API and report
          --ram                   Print RSS after every tool call (debug memory growth)
          -v, --version           Show version
          -h, --help              Show this help

          (no -p flag)            Interactive TUI mode
                                  Type / for slash commands

        Environment:
          MOONSHOT_API_KEY        API key for Moonshot
          MOONSHOT_ENDPOINT       API endpoint (default: https://api.kimi.com/coding/v1)
          MOONSHOT_MODEL          Default model name
          HCODE_PROVIDER          Provider: moonshot | zai | zai-coding-plan | mock
          HCODE_HOME              Config directory (default: ~/.hcode)
          HTTP_PROXY              HTTP/HTTPS proxy URL
          ALL_PROXY               SOCKS proxy URL
          HCODE_DEBUG             Show backtraces on error
        USAGE
    end
  end

  # Bridge AskUserQuestion tool → TUI QuestionDialog. When the tool calls
  # `QuestionService#request`, this spawns a fiber that pushes the questions
  # into the App's dialog, waits for the user's answer on a channel, and
  # returns it. Mirrors TS `reverse-rpc/question-adapter.ts`.
  class AppQuestionService < Tools::QuestionService
    def initialize(@app : TUI::App)
    end

    def request(req : Tools::QuestionRequest, signal : ::Hcode::Loop::AbortController?) : Tools::QuestionResult?
      # Capacity 1: the dialog's callback runs synchronously inside
      # handle_input, so a rendezvous channel would deadlock (send waits
      # for receive, receive can't start until handle_input returns).
      result_chan = Channel(Tools::QuestionResult).new(1)

      spawn do
        answers = @app.request_questions(req.questions)
        result_chan.send(answers)
      end

      # Block this turn fiber until the user answers. The agent loop's abort
      # signal is handled separately by the tool layer; here we just wait.
      result_chan.receive
    end
  end

  # Bridge ExitPlanMode tool → TUI PlanReviewDialog. When the tool calls
  # `PlanReviewService#request` in manual / yolo permission mode, this pushes
  # the finalized plan into the App's review dialog and blocks until the user
  # decides (Approve / Revise / Reject & Exit / Cancel).
  class AppPlanReviewService < Tools::PlanReviewService
    def initialize(@app : TUI::App)
    end

    def request(plan : String, path : String?,
               options : Array(Tools::PlanOption)?) : Tools::PlanReviewResult?
      @app.request_plan_review(plan, path, options)
    end
  end
end

Hcode::CLI.run(ARGV) unless ARGV.includes?("--no-cli-run")
