module Hcode
  module LLM
    # One scripted step of a MockProvider replay: the MessageParts to stream
    # through the block and the stop_reason to report. A step whose stop_reason
    # is "tool_use" (or that carries tool_calls) forces the agent loop to
    # dispatch those calls in parallel and loop again; a step with no tool
    # calls and "end_turn" terminates the loop.
    struct MockStep
      property parts : Array(MessagePart)
      property stop_reason : String
      property text : String
      # Delay (ms) to sleep before emitting each part. Simulates network
      # streaming latency so the TUI's live render can be exercised.
      property part_delay_ms : Int32 = 0

      def initialize(@parts : Array(MessagePart), @stop_reason : String = "end_turn",
                     @text : String = "", @part_delay_ms : Int32 = 0)
      end
    end

    # Deterministic, offline provider for agent-loop integration tests and
    # token-free manual demos. Instead of calling an LLM it replays a fixed
    # script step by step: each `chat` call returns the next MockStep,
    # streaming its parts through the block exactly like a real provider, so
    # the agent's run_turn / parallel tool batch / termination all execute
    # against real tool calls — with no network or API key.
    #
    # Select it at runtime via `HCODE_PROVIDER=mock` or `[provider] default =
    # "mock"` to exercise the loop without burning tokens.
    class MockProvider < Provider
      DEFAULT_MODEL = "mock"

      # Built-in self-test script: two parallel tool calls (Glob + Bash), then
      # a Write, then a final text step with no tool calls so the loop stops.
      DEFAULT_SCRIPT = [
        MockStep.new(
          parts: [
            ToolCallPart.new("m_call_1", "Glob", %({"pattern":"*"})),
            ToolCallPart.new("m_call_2", "Bash", %({"command":"echo mock-selftest-ok"})),
          ] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_call_fail", "Bash", %({"command":"echo step2"}))] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_call_3", "Write", %({"path":".mock-selftest","content":"mock ran"}))] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [TextPart.new("Mock self-test complete.")] of MessagePart,
          stop_reason: "end_turn",
          text: "Mock self-test complete.",
        ),
      ] of MockStep

      # Thinking-only demo: ~5 s of streamed reasoning (10 ThinkParts × 500 ms),
      # then a short text answer. Use with:
      #   HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=thinking
      THINKING_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            ThinkPart.new("Let me analyze this request carefully."),
            ThinkPart.new(" The user wants me to examine the project structure."),
            ThinkPart.new(" I should start by checking the configuration files"),
            ThinkPart.new(" like shard.yml to understand the dependencies."),
            ThinkPart.new(" Then I need to look at the source directory layout"),
            ThinkPart.new(" to understand how modules are organized."),
            ThinkPart.new(" I also want to review the main entry point"),
            ThinkPart.new(" and trace how the agent loop is initialized."),
            ThinkPart.new(" After that, I can formulate a clear answer"),
            ThinkPart.new(" summarizing the architecture for the user."),
            TextPart.new("I've analyzed the project. It's a Crystal agent with an LLM provider layer, a tool registry, and a TUI."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "I've analyzed the project. It's a Crystal agent with an LLM provider layer, a tool registry, and a TUI.",
          part_delay_ms: 500,
        ),
      ] of MockStep

      # Thinking + tools demo: ~3 s of reasoning, then a Glob tool call, then
      # a final text answer. Tests the thinking → tool-call transition.
      #   HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=thinking-tools
      THINKING_TOOLS_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            ThinkPart.new("Let me think about what files to examine."),
            ThinkPart.new(" I should list the source files first."),
            ThinkPart.new(" A Glob call with pattern \"src/**/*.cr\" would work."),
            ThinkPart.new(" Let me do that now."),
            ToolCallPart.new("m_think_1", "Glob", %({"pattern":"src/**/*.cr"})),
          ] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 600,
        ),
        MockStep.new(
          parts: [
            TextPart.new("I found the source files. The project is well-organized."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "I found the source files. The project is well-organized.",
        ),
      ] of MockStep

      # Markdown rendering demo: streams a reply that exercises the TUI's
      # markdown renderer — headings, emphasis, inline code, lists, a fenced
      # code block, a table, a blockquote and a horizontal rule. Use with:
      #   HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=markdown
      MARKDOWN_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            TextPart.new("# Markdown Rendering Demo\n\n"),
            TextPart.new("This reply exercises the terminal **markdown** renderer. "),
            TextPart.new("It has *italics*, `inline code`, and a [link](https://example.com).\n\n"),
            TextPart.new("## Unordered list\n\n"),
            TextPart.new("- First item\n- Second item\n- Third item\n\n"),
            TextPart.new("## Ordered steps\n\n"),
            TextPart.new("1. Read the source\n2. Run the tests\n3. Ship it\n\n"),
            TextPart.new("## Code block\n\n"),
            TextPart.new("```crystal\n"),
            TextPart.new("def greet(name : String)\n  puts \"Hello, \#{name}!\"\nend\n\n"),
            TextPart.new("greet(\"world\")\n"),
            TextPart.new("```\n\n"),
            TextPart.new("## Table\n\n"),
            TextPart.new("| File | Purpose |\n| --- | --- |\n| `src/hcode.cr` | Entry point |\n| `src/llm/` | Provider layer |\n| `src/tui/` | Terminal UI |\n| `src/tui/markdown.cr` | Markdown renderer with ANSI-aware wrapping, cell overflow, and inline code styling — handles tables, lists, blockquotes, code fences, horizontal rules, headings, bold, italic, strikethrough, links, task lists, nested structures, wide characters, emoji width measurement, and proportional column shrinking when content exceeds terminal width |\n\n"),
            TextPart.new("> Markdown renders cleanly in the terminal.\n\n"),
            TextPart.new("---\n\n"),
            TextPart.new("That covers every block the renderer supports."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "Markdown rendering demo complete.",
          part_delay_ms: 80,
        ),
      ] of MockStep

      property model : String
      property script : Array(MockStep)
      @step : Int32 = 0

      def initialize(@script : Array(MockStep) = DEFAULT_SCRIPT.dup, @model : String = DEFAULT_MODEL)
      end

      # Select a named demo script via HCODE_MOCK_SCRIPT env var.
      # Returns nil if the env var is unset or doesn't match a known script.
      def self.script_from_env : Array(MockStep)?
        case ENV["HCODE_MOCK_SCRIPT"]?
        when "thinking"       then THINKING_DEMO_SCRIPT.dup
        when "thinking-tools" then THINKING_TOOLS_DEMO_SCRIPT.dup
        when "markdown"       then MARKDOWN_DEMO_SCRIPT.dup
        else                       nil
        end
      end

      def name : String
        "mock"
      end

      def model_name : String
        @model
      end

      def fetch_models : Array(String)
        [@model]
      end

      # Rewind the script to the first step (used between runs in tests).
      def reset : Nil
        @step = 0
      end

      def chat(messages : Array(Message), tools : Array(ToolDefinition)?,
               system_prompt : String? = nil, aborted? : -> Bool = -> { false },
               &block : MessagePart ->) : StepResult
        current = @script[@step]? || @script.last
        @step += 1

        tool_calls = [] of ToolCall
        text = IO::Memory.new

        current.parts.each do |part|
          sleep current.part_delay_ms.milliseconds if current.part_delay_ms > 0
          case part
          when TextPart
            text << part.text
          when ToolCallPart
            tool_calls << ToolCall.new(part.id, ToolCallFunction.new(part.name, part.arguments))
          end
          block.call(part)
        end

        usage = Usage.new(prompt_tokens: 10, completion_tokens: 5, total_tokens: 15)
        block.call(UsagePart.new(usage))
        block.call(FinishPart.new(current.stop_reason))

        StepResult.new(
          stop_reason: current.stop_reason,
          text: current.text.empty? ? text.to_s : current.text,
          tool_calls: tool_calls,
          usage: usage,
        )
      end
    end
  end
end
