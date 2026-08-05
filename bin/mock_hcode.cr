#!/usr/bin/env crystal
#
# mock-hcode — standalone test binary that drives the real TUI with
# simulated LLM output. Runs 100 tool calls with hardcoded results so you
# can visually inspect rendering bugs (logo reappearing, flicker, etc.)
# in a real terminal.
#
# Build:   crystal build bin/mock_hcode.cr -o bin/mock_hcode --release
# Run:     ./bin/mock-hcode

require "../src/version"
require "../src/version_compare"
require "../src/upgrader"
require "../src/exception_handler"
require "../src/llm/types"
require "../src/llm/token_counter"
require "../src/llm/http_transport"
require "../src/llm/provider"
require "../src/llm/openai_chat_provider"
require "../src/llm/moonshot_provider"
require "../src/llm/zai_provider"
require "../src/llm/ollama_provider"
require "../src/llm/lmstudio_provider"
require "../src/llm/mock_provider"
require "../src/tools/tool"
require "../src/tools/registry"
require "../src/tools/line_endings"
require "../src/tools/path_access"
require "../src/tools/run_rg"
require "../src/tools/bash"
require "../src/tools/read"
require "../src/tools/write"
require "../src/tools/edit"
require "../src/tools/glob"
require "../src/tools/grep"
require "../src/tools/todo_list"
require "../src/tools/agent_swarm"
require "../src/tools/agent"
require "../src/tools/ask_user_question"
require "../src/tools/fetch_url"
require "../src/tools/web_search"
require "../src/tools/skill"
require "../src/tools/plan_mode"
require "../src/tools/goal"
require "../src/tools/task"
require "../src/tools/cron"
require "../src/tools/read_media"
require "../src/tools/select_tools"
require "../src/mcp/types"
require "../src/mcp/tool_naming"
require "../src/mcp/transport"
require "../src/mcp/jsonrpc"
require "../src/mcp/config"
require "../src/mcp/client"
require "../src/mcp/proxy_tool"
require "../src/mcp/manager"
require "../src/mcp/http_transport"
require "../src/context/memory"
require "../src/context/budget"
require "../src/context/undo"
require "../src/context/overflow"
require "../src/context/compaction"
require "../src/profiled_memory"
require "../src/permission/manager"
require "../src/permission/danger"
require "../src/permission/policies"
require "../src/loop/events"
require "../src/loop/abort"
require "../src/loop/dedup"
require "../src/loop/tool_batch"
require "../src/loop/agent"
require "../src/loop/subagent_registry"
require "../src/loop/subagent_agent_runner"
require "../src/loop/subagent_swarm_runner"
require "../src/prompt/template"
require "../src/prompt/agents_md"
require "../src/prompt/system_prompt"
require "../src/session/store"
require "../src/session/index"
require "../src/session/lifecycle"
require "../src/tui/theme"
require "../src/tui/terminal"
require "../src/tui/char_width"
require "../src/tui/markdown"
require "../src/tui/input_wait"
require "../src/tui/input"
require "../src/tui/component"
require "../src/tui/text"
require "../src/tui/spinner"
require "../src/tui/editor"
require "../src/tui/fuzzy"
require "../src/tui/select_list"
require "../src/tui/help_panel"
require "../src/tui/commands"
require "../src/tui/question_dialog"
require "../src/tui/plan_review_dialog"
require "../src/tui/undo_dialog"
require "../src/tui/tasks_browser"
require "../src/tui/setup_controller"
require "../src/tui/command_controller"
require "../src/tui/app_models"
require "../src/tui/event_controller"
require "../src/tui/input_controller"
require "../src/tui/turn_controller"
require "../src/tui/render_controller"
require "../src/tui/message_renderer"
require "../src/tui/ui_panels"
require "../src/tui/terminal_port"
require "../src/tui/terminal_mock"
require "../src/tui/ansi_terminal_port"
require "../src/tui/log_zone"
require "../src/tui/active_zone"
require "../src/tui/app"
require "../src/tui/diff"
require "../src/tui/usage_panel"
require "../src/setup/wizard"
require "../src/notify/config"
require "../src/notify/status"
require "../src/notify/terminal"
require "../src/notify/player"
require "../src/notify/webhook"
require "../src/notify/dispatcher"
require "../src/config/config"
require "../src/i18n/i18n"
require "../src/hooks/engine"
require "../src/plugin/types"
require "../src/plugin/store"
require "../src/plugin/source"
require "../src/plugin/manifest"
require "../src/plugin/commands"
require "../src/plugin/manager"

Hcode::I18n.init("en")

module Hcode
  module MockHcode
    TOOLS = [
      {"Read", %({"path": "src/main.ts"}), "1  import { createApp } from 'vue'\n2  import { createPinia } from 'pinia'\n3  import App from './App.vue'\n4  import router from './router'\n5  import './style.css'\n6  \n7  const app = createApp(App)\n8  app.use(createPinia())\n9  app.use(router)\n10  app.mount('#app')"},
      {"Grep", %({"pattern": "isActive", "path": "src"}), "src/store/auth.ts:42:  const isActive = computed(() => !!token.value)\nsrc/store/auth.ts:58:  function checkActive() {\nsrc/components/Header.vue:12:  const { isActive } = useAuth()\nsrc/views/Dashboard.vue:8:  v-if=\"isActive\""},
      {"Glob", %({"pattern": "**/*.ts"}), "src/main.ts\nsrc/store/auth.ts\nsrc/store/index.ts\nsrc/router/index.ts\nsrc/api/client.ts\nsrc/api/types.ts\nsrc/utils/format.ts\nsrc/utils/date.ts\nsrc/composables/useAuth.ts\nsrc/composables/useApi.ts"},
      {"Bash", %({"command": "npm test"}), "PASS src/store/auth.test.ts\nPASS src/api/client.test.ts\nPASS src/utils/format.test.ts\nTests: 3 passed, 3 total\nTime:  2.341s"},
      {"Edit", %({"path": "src/store/auth.ts", "old_string": "const isActive = computed(() => !!token.value)", "new_string": "const isActive = computed(() => !!token.value && !isExpired(token.value))"}), ""},
      {"Write", %({"path": "src/utils/validation.ts", "content": "export function isValid(date: string): boolean { ... }"}), ""},
      {"TodoList", %({"todos": [{"title": "Fix key validation", "status": "in_progress"}, {"title": "Add expiry check", "status": "pending"}, {"title": "Update tests", "status": "pending"}]}), "Todo list updated."},
      {"Read", %({"path": "src/components/Header.vue"}), "1  <template>\n2    <header class=\"header\">\n3      <nav>\n4        <RouterLink to=\"/\">Home</RouterLink>\n5        <RouterLink to=\"/about\">About</RouterLink>\n6      </nav>\n7      <UserMenu v-if=\"isActive\" />\n8    </header>\n9  </template>"},
      {"Grep", %({"pattern": "expires|expiry", "path": "src"}), "src/store/auth.ts:15:  const expiresAt = ref<string | null>(null)\nsrc/store/auth.ts:43:  const isActive = computed(() => !!token.value)\nsrc/api/client.ts:28:  headers['X-Expiry'] = getExpiry()"},
      {"Bash", %({"command": "git diff --stat"}), " src/store/auth.ts   | 12 ++++++----\n src/utils/validation.ts | 45 +++++++++++++++++++++++++++++\n 2 files changed, 53 insertions(+), 5 deletions(-)"},
      {"ExitPlanMode", %({"options": [{"label": "Centralized validation util (Recommended)", "description": "Single isExpired helper reused across the app"}, {"label": "Inline expiry check", "description": "Add expiry logic directly in the auth store computed"}]}), "Exited plan mode. Plan mode deactivated. All tools are now available.\nPlan saved to: plan/auth-expiry.md\n\n## Approved Plan:\n## Add token-expiry validation to the auth store\n\n1. Create `src/utils/validation.ts` with an `isExpired(token)` helper that decodes the expiry claim.\n2. Update `isActive` computed in `src/store/auth.ts` to AND-in `!isExpired(token.value)`.\n3. Verify `Header.vue` reacts automatically — it already reads `isActive`, so no change is needed.\n4. Add unit tests in `src/store/auth.test.ts` covering expired, valid, and missing-token cases.\n\nSelected approach: Centralized validation util\nExecute ONLY the selected approach. Do not execute any unselected alternatives."},
      {"WebSearch", %({"query": "vue 3 token expiry check computed property best practices"}), "---\n\nTitle: Computed Properties | Vue.js\nSite: vuejs.org\nURL: https://vuejs.org/guide/essentials/computed.html\nSnippet: Computed properties are reactive and cached based on their reactive dependencies. A computed property only re-evaluates when some of its dependencies change.\n\n---\n\nTitle: Handling JWT Token Expiry in SPAs\nSite: stackoverflow.com\nDate: 2024-03-12\nURL: https://stackoverflow.com/questions/7684357\nSnippet: A common pattern is to invalidate the session when the token expires and redirect the user to login.\n\nWhen you rely on a result in your answer, cite its source URL so the user can verify it."},
      {"FetchURL", %({"url": "https://vuejs.org/guide/essentials/computed.html"}), "The returned content is the main text extracted from the page.\n\n# Computed Properties\n\nComputed properties are reactive and cached based on their reactive dependencies. A computed property only re-evaluates when some of its reactive dependencies change. This is useful when you have expensive logic that should not run on every render.\n\n## Computed Caching vs Methods\n\nA method call will always run the function whenever a re-render happens, whereas a computed property is cached and only re-evaluates when its dependencies change.\n\nIf you use it in your answer, cite this page as a markdown link, e.g. [title](url)."},
      {"Skill", %({"skill": "fix-bash", "args": "npm test"}), "Skill \"fix-bash\" loaded inline. Follow its instructions."},
      {"CreateGoal", %({"objective": "Make keys invalid after the deadline passes", "completionCriterion": "isActive returns false when token is expired"}), "{\n  \"goal\": {\n    \"objective\": \"Make keys invalid after the deadline passes\",\n    \"completionCriterion\": \"isActive returns false when token is expired\",\n    \"status\": \"active\",\n    \"turnsUsed\": 0,\n    \"tokensUsed\": 0,\n    \"wallClockMs\": 12,\n    \"budget\": { \"tokenBudget\": null, \"turnBudget\": null, \"wallClockBudgetMs\": null, \"remainingTokens\": null, \"remainingTurns\": null, \"remainingWallClockMs\": null, \"tokenBudgetReached\": false, \"turnBudgetReached\": false, \"wallClockBudgetReached\": false, \"overBudget\": false },\n    \"terminalReason\": null\n  }\n}"},
    ]

    THINKING_SNIPPETS = [
      "Let me analyze the codebase structure and understand how the key validation works.",
      "I need to check the expiry date logic in the auth store and see where it's being used.",
      "The issue is that `isActive` only checks for token presence, not expiry. I should add an expiry check.",
      "Looking at the Header component, it uses `isActive` to conditionally render the user menu.",
      "I should create a utility function to check if the deadline has passed.",
      "Now I need to update the auth store to use the new validation function.",
      "Let me run the tests to make sure everything works correctly.",
      "The grep results show several places where expiry is referenced. Let me trace through them.",
      "I'll update the computed property to also check the deadline.",
      "Let me verify the changes are correct by reading the updated file.",
    ]

    TEXT_SNIPPETS = [
      "I'll start by examining the current authentication setup.",
      "Now I can see the issue — the `isActive` computed property doesn't check expiry.",
      "Let me create a validation utility to handle deadline checks.",
      "I'll update the auth store to use the new utility.",
      "Running tests to verify the changes work correctly.",
      "The grep results show the expiry logic is scattered across multiple files.",
      "Let me refactor this into a centralized validation function.",
      "Now I'll update the components to use the new logic.",
      "Let me check the git diff to review all changes.",
      "Everything looks good. The key validation now properly checks expiry.",
    ]

    # Build a plan whose rendered height comfortably exceeds 2× the
    # terminal viewport, so the Log zone receives a chunk bigger than the
    # screen — used to exercise large-block emission and scroll behavior.
    def self.build_big_plan : String
      rows = Hcode::TUI::Terminal.current.rows
      target = (rows * 2) + 30
      String.build do |s|
        s << "## Plan — large render test (#{target} lines, viewport #{rows})\n"
        s << "A plan block larger than 2× the viewport, written into the Log.\n\n"
        target.times do |i|
          s << "#{i + 1}. Step number #{i + 1}: validate rendering at log line #{i + 1} of #{target}.\n"
        end
      end
    end

    # Build an assistant response whose rendered height comfortably exceeds
    # the terminal viewport. Unlike build_big_plan, this one is meant to be
    # STREAMED word-by-word via text_delta into the Active zone — not flushed
    # as a finished block into the Log. This reproduces the architectural bug
    # where a long streamed LLM answer (the chat-icon block) overflows the
    # Active area and produces redraw artifacts.
    def self.build_big_streamed_response : String
      rows = Hcode::TUI::Terminal.current.rows
      target = (rows * 2) + 20
      String.build do |s|
        s << "Here is a detailed explanation that is intentionally longer than the viewport "
        s << "(#{target} lines, viewport #{rows}) so we can watch the Active zone overflow "
        s << "while it streams.\n\n"
        target.times do |i|
          s << "Line #{i + 1} of #{target}: streamed assistant token, rendered inside the active chat block.\n"
        end
      end
    end

    def self.run : Nil
      config = Hcode::Config::Config.load

      app = Hcode::TUI::App.new
      app.model = "mock-model"
      app.provider_name = "mock"
      app.permission_mode = "yolo"
      app.work_dir = Dir.current
      app.debug_zones = config.debug_zones

      puts "mock-hcode: simulating 100 tool calls. Press Ctrl+C to exit."

      app.run(initial_prompt: "Fix the frontend key validation — key should become invalid when the deadline passes.") do |_text, _persisted|
        spawn do
          # Emit a plan block larger than 2× the viewport straight into the Log
          # zone. It must NOT be streamed via text_delta: the Active zone is only
          # for the small repainted region (spinner, live preview, editor), and a
          # viewport-sized streaming block violates the two-zone model.
          plan = build_big_plan
          app.on_event(Hcode::Loop::Event.step_begin(0))
          sleep 80.milliseconds
          app.on_event(Hcode::Loop::Event.assistant_text(plan))
          sleep 50.milliseconds

          # Reproduce the Active-zone overflow bug: stream a large assistant
          # answer via text_delta (word-by-word) instead of flushing it as a
          # finished block. The Active area holds the in-progress chat-icon
          # block, and a response taller than the viewport causes redraw
          # artifacts as the repainted region exceeds its budget.
          app.on_event(Hcode::Loop::Event.step_begin(0))
          sleep 80.milliseconds
          big_response = build_big_streamed_response
          big_response.split(" ").each_with_index do |word, wi|
            app.on_event(Hcode::Loop::Event.text_delta(word + (wi == 0 ? "" : " ")))
            sleep 15.milliseconds
          end
          sleep 50.milliseconds
          app.on_event(Hcode::Loop::Event.assistant_text(big_response))
          sleep 50.milliseconds

          100.times do |i|
            tool = TOOLS[i % TOOLS.size]
            tool_name = tool[0]
            tool_args = tool[1]
            tool_result_text = tool[2]
            step = i

            # Step begin
            app.on_event(Hcode::Loop::Event.step_begin(step))
            sleep 80.milliseconds

            # Thinking (stream a few tokens)
            thinking = THINKING_SNIPPETS[i % THINKING_SNIPPETS.size]
            thinking.split(" ").each_with_index do |word, wi|
              app.on_event(Hcode::Loop::Event.thinking_delta(word + (wi == 0 ? "" : " ")))
              sleep 30.milliseconds
            end
            sleep 50.milliseconds

            # Short assistant text before tool
            text = TEXT_SNIPPETS[i % TEXT_SNIPPETS.size]
            words = text.split(" ")
            words.each_with_index do |word, wi|
              app.on_event(Hcode::Loop::Event.text_delta(word + (wi == words.size - 1 ? "" : " ")))
              sleep 25.milliseconds
            end
            sleep 50.milliseconds

            # Tool call
            tool_id = "tc_#{i}"
            app.on_event(Hcode::Loop::Event.tool_call_start(tool_id, tool_name, tool_args))
            sleep 100.milliseconds

            # Tool result
            app.on_event(Hcode::Loop::Event.tool_result(tool_id, tool_result_text, false))
            sleep 80.milliseconds
          end

          # Final assistant text
          final = "I've completed all the changes. The frontend now properly validates key expiry — when the deadline passes, the key automatically becomes invalid."
          final.split(" ").each_with_index do |word, wi|
            app.on_event(Hcode::Loop::Event.text_delta(word + (wi == 0 ? "" : " ")))
            sleep 30.milliseconds
          end
          sleep 50.milliseconds

          app.on_event(Hcode::Loop::Event.assistant_text(final))
          app.on_event(Hcode::Loop::Event.turn_end)
        end
      end
    end
  end
end

Hcode::MockHcode.run
