#!/usr/bin/env crystal
#
# mockfast-hcode — standalone test binary that drives the real TUI with
# simulated LLM output. Runs just a couple of tool calls (plus one big
# plan block into the Log zone) so you can quickly eyeball rendering
# without waiting through 100 iterations like mock-hcode.
#
# Build:   crystal build bin/mockfast_hcode.cr -o bin/mockfast_hcode --release
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
  module MockFastHcode
    # Just a couple of tool calls — enough to eyeball rendering without
    # waiting through the full 100-iteration mock-hcode run.
    TOOLS = [
      {"Read", %({"path": "src/store/auth.ts"}), "1  import { defineStore } from 'pinia'\n2  import { ref, computed } from 'vue'\n3  \n4  export const useAuthStore = defineStore('auth', () => {\n5    const token = ref<string | null>(null)\n6    const isActive = computed(() => !!token.value)\n7    return { token, isActive }\n8  })"},
      {"Grep", %({"pattern": "isActive", "path": "src"}), "src/store/auth.ts:6:  const isActive = computed(() => !!token.value)\nsrc/components/Header.vue:12:  const { isActive } = useAuth()\nsrc/views/Dashboard.vue:8:  v-if=\"isActive\""},
    ]

    THINKING_SNIPPETS = [
      "The isActive computed only checks token presence, not expiry. I need to add an expiry check.",
      "Grep confirms isActive is used in Header.vue and Dashboard.vue, so a centralized fix will propagate everywhere.",
    ]

    TEXT_SNIPPETS = [
      "Let me read the auth store to see how the key validation works.",
      "I'll grep for isActive to find every consumer of the computed property.",
    ]

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

    def self.run : Nil
      config = Hcode::Config::Config.load

      app = Hcode::TUI::App.new
      app.model = "mock-model"
      app.provider_name = "mock"
      app.permission_mode = "yolo"
      app.work_dir = Dir.current
      app.debug_zones = config.debug_zones

      puts "mockfast-hcode: simulating a couple of tool calls. Press Ctrl+C to exit."

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

          TOOLS.each_with_index do |tool, i|
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
          final = "Done. The frontend now validates key expiry — when the deadline passes, the key becomes invalid."
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

Hcode::MockFastHcode.run
