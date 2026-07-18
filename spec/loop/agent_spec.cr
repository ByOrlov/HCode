require "../spec_helper"
require "../../src/loop/agent"
require "random/secure"

# Integration coverage for the agent loop, driven end-to-end by the offline
# MockProvider. No network, no API key: the mock replays a fixed multi-step
# script (parallel tool calls → write → finish) so run_turn, the parallel
# tool batch, result assembly, and termination all execute against real tools.
describe Kimi::Loop::Agent do
  it "runs a multi-step turn with parallel tool calls on the mock provider" do
    work_dir = File.join(Dir.tempdir, "kimi-mock-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      provider = Kimi::LLM::MockProvider.new
      memory = Kimi::Context::Memory.new
      memory.max_context_tokens = 131_072

      tools = Kimi::Tools::Registry.new
      tools.register(Kimi::Tools::Bash.new(work_dir))
      tools.register(Kimi::Tools::Glob.new(work_dir))
      tools.register(Kimi::Tools::Write.new(work_dir))

      permission = Kimi::Permission::Manager.new(Kimi::Permission::Mode::Yolo)
      agent = Kimi::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of Kimi::Loop::Event
      result = agent.run_turn("self-test", nil) { |e| events << e }

      # The script ends on an end_turn step with no tool calls.
      result.stop_reason.should eq("end_turn")
      result.steps.should eq(4)
      result.usage.total_tokens.should be > 0

      # Every scripted tool call was dispatched and completed without error.
      started = events.select { |e| e.type.tool_call_start? }.map(&.tool_name)
      started.sort.should eq(["Bash", "Bash", "Glob", "Write"])

      tool_results = events.select { |e| e.type.tool_result? }
      tool_results.size.should eq(4)
      tool_results.all? { |e| !e.is_error }.should be_true

      # The Write tool actually wrote the file — proving tool execution ran,
      # not just that events fired.
      File.exists?(File.join(work_dir, ".mock-selftest")).should be_true
    ensure
      File.delete(File.join(work_dir, ".mock-selftest")) rescue nil
      Dir.delete(work_dir) rescue nil
    end
  end

  it "accumulates assistant text from the final step" do
    provider = Kimi::LLM::MockProvider.new([
      Kimi::LLM::MockStep.new(
        parts: [Kimi::LLM::TextPart.new("all done here")] of Kimi::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "all done here",
      ),
    ])
    memory = Kimi::Context::Memory.new
    tools = Kimi::Tools::Registry.new
    permission = Kimi::Permission::Manager.new(Kimi::Permission::Mode::Yolo)
    agent = Kimi::Loop::Agent.new(provider, memory, tools, permission)

    result = agent.run_turn("hi", nil) { }

    result.stop_reason.should eq("end_turn")
    result.steps.should eq(1)
    memory.messages.last.role.should eq("assistant")
    memory.messages.last.content.should eq("all done here")
  end

  it "hot-swaps the provider at runtime via swap_provider!" do
    first = Kimi::LLM::MockProvider.new([
      Kimi::LLM::MockStep.new(
        parts: [Kimi::LLM::TextPart.new("first")] of Kimi::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "first",
      ),
    ])
    second = Kimi::LLM::MockProvider.new([
      Kimi::LLM::MockStep.new(
        parts: [Kimi::LLM::TextPart.new("second")] of Kimi::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "second",
      ),
    ])

    memory = Kimi::Context::Memory.new
    tools = Kimi::Tools::Registry.new
    permission = Kimi::Permission::Manager.new(Kimi::Permission::Mode::Yolo)
    agent = Kimi::Loop::Agent.new(first, memory, tools, permission)

    agent.provider.should be(first)
    agent.run_turn("turn one", nil) { }
    memory.messages.last.content.should eq("first")

    agent.swap_provider!(second)
    agent.provider.should be(second)

    agent.run_turn("turn two", nil) { }
    memory.messages.last.content.should eq("second")
  end

  it "emits ThinkingDelta events when the provider streams ThinkParts" do
    provider = Kimi::LLM::MockProvider.new([
      Kimi::LLM::MockStep.new(
        parts: [
          Kimi::LLM::ThinkPart.new("Let me analyze"),
          Kimi::LLM::ThinkPart.new(" this problem."),
          Kimi::LLM::TextPart.new("Here is the answer."),
        ] of Kimi::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "Here is the answer.",
      ),
    ])
    memory = Kimi::Context::Memory.new
    tools = Kimi::Tools::Registry.new
    permission = Kimi::Permission::Manager.new(Kimi::Permission::Mode::Yolo)
    agent = Kimi::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of Kimi::Loop::Event
    agent.run_turn("test", nil) { |e| events << e }

    thinking_deltas = events.select(&.type.thinking_delta?)
    thinking_deltas.size.should eq(2)
    thinking_deltas[0].text.should eq("Let me analyze")
    thinking_deltas[1].text.should eq(" this problem.")

    text_deltas = events.select(&.type.text_delta?)
    text_deltas.size.should eq(1)
    text_deltas[0].text.should eq("Here is the answer.")
  end
end
