require "../spec_helper"
require "../../src/loop/agent"
require "random/secure"

# Provider that always raises an IO::Error to simulate a network drop.
private class NetworkDropProvider < Hcode::LLM::Provider
  def name : String
    "network-drop"
  end

  def model_name : String
    "test"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(Hcode::LLM::Message), tools : Array(Hcode::LLM::ToolDefinition)?,
           system_prompt : String? = nil, aborted? : -> Bool = -> { false },
           &block : Hcode::LLM::MessagePart ->) : Hcode::LLM::StepResult
    raise IO::Error.new("Broken pipe")
  end
end

# Integration coverage for the agent loop, driven end-to-end by the offline
# MockProvider. No network, no API key: the mock replays a fixed multi-step
# script (parallel tool calls → write → finish) so run_turn, the parallel
# tool batch, result assembly, and termination all execute against real tools.
describe Hcode::Loop::Agent do
  it "runs a multi-step turn with parallel tool calls on the mock provider" do
    work_dir = File.join(Dir.tempdir, "hcode-mock-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      provider = Hcode::LLM::MockProvider.new
      memory = Hcode::Context::Memory.new
      memory.max_context_tokens = 131_072

      tools = Hcode::Tools::Registry.new
      tools.register(Hcode::Tools::Bash.new(work_dir))
      tools.register(Hcode::Tools::Glob.new(work_dir))
      tools.register(Hcode::Tools::Write.new(work_dir))

      permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
      agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of Hcode::Loop::Event
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
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("all done here")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "all done here",
      ),
    ])
    memory = Hcode::Context::Memory.new
    tools = Hcode::Tools::Registry.new
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

    result = agent.run_turn("hi", nil) { }

    result.stop_reason.should eq("end_turn")
    result.steps.should eq(1)
    memory.messages.last.role.should eq("assistant")
    memory.messages.last.content.should eq("all done here")
  end

  it "hot-swaps the provider at runtime via swap_provider!" do
    first = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("first")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "first",
      ),
    ])
    second = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("second")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "second",
      ),
    ])

    memory = Hcode::Context::Memory.new
    tools = Hcode::Tools::Registry.new
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(first, memory, tools, permission)

    agent.provider.should be(first)
    agent.run_turn("turn one", nil) { }
    memory.messages.last.content.should eq("first")

    agent.swap_provider!(second)
    agent.provider.should be(second)

    agent.run_turn("turn two", nil) { }
    memory.messages.last.content.should eq("second")
  end

  it "emits ThinkingDelta events when the provider streams ThinkParts" do
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [
          Hcode::LLM::ThinkPart.new("Let me analyze"),
          Hcode::LLM::ThinkPart.new(" this problem."),
          Hcode::LLM::TextPart.new("Here is the answer."),
        ] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "Here is the answer.",
      ),
    ])
    memory = Hcode::Context::Memory.new
    tools = Hcode::Tools::Registry.new
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of Hcode::Loop::Event
    agent.run_turn("test", nil) { |e| events << e }

    thinking_deltas = events.select(&.type.thinking_delta?)
    thinking_deltas.size.should eq(2)
    thinking_deltas[0].text.should eq("Let me analyze")
    thinking_deltas[1].text.should eq(" this problem.")

    text_deltas = events.select(&.type.text_delta?)
    text_deltas.size.should eq(1)
    text_deltas[0].text.should eq("Here is the answer.")
  end

  it "emits exactly one TurnEnd at the end of a normal turn" do
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("ok")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ok",
      ),
    ])
    memory = Hcode::Context::Memory.new
    tools = Hcode::Tools::Registry.new
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of Hcode::Loop::Event
    agent.run_turn("x", nil) { |e| events << e }

    turn_ends = events.select(&.type.turn_end?)
    turn_ends.size.should eq(1)
    turn_ends.first.is_error.should be_false  # not cancelled
    # TurnEnd must be the last event so the TUI can safely drain the queue.
    events.last.type.turn_end?.should be_true
  end

  it "emits TurnEnd even when the turn is cancelled" do
    # Tool call that sleeps 30s gives the cancel a window to fire mid-tool.
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new(
          "call_1", "Bash", %({"command":"sleep 30"})
        )] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
    ])
    work_dir = File.join(Dir.tempdir, "hcode-cancel-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)
    begin
      memory = Hcode::Context::Memory.new
      tools = Hcode::Tools::Registry.new
      tools.register(Hcode::Tools::Bash.new(work_dir))
      permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
      agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of Hcode::Loop::Event
      expect_raises(Hcode::Loop::UserCancellationError) do
        # Cancel from a sibling fiber once the tool step is in flight.
        spawn do
          sleep 50.milliseconds
          agent.cancel
        end
        agent.run_turn("x", nil) { |e| events << e }
      end

      turn_ends = events.select(&.type.turn_end?)
      turn_ends.size.should eq(1)
      turn_ends.first.is_error.should be_true  # cancelled flag
    ensure
      Dir.delete(work_dir) rescue nil
    end
  end

  it "injects a steering message into the live context via #steer" do
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("ack")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ack",
      ),
    ])
    memory = Hcode::Context::Memory.new
    tools = Hcode::Tools::Registry.new
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

    agent.context.history.size.should eq(0)
    agent.steer("a side note")
    agent.context.history.size.should eq(1)
    agent.context.history.last.message.role.should eq("user")
    agent.context.history.last.message.content.should eq("a side note")
  end

  it "raises NetworkFailureError after exhausting retries on a network error" do
    provider = NetworkDropProvider.new
    memory = Hcode::Context::Memory.new
    memory.max_context_tokens = 131_072
    tools = Hcode::Tools::Registry.new
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of Hcode::Loop::Event
    error = expect_raises(Hcode::Loop::NetworkFailureError) do
      agent.run_turn("hi", nil) { |e| events << e }
    end

    (error.message || "").should contain("Network failure")
    (error.message || "").should contain("3 retries")
    (error.message || "").should contain("Broken pipe")

    # The user should have seen retry info messages.
    retry_infos = events.select(&.type.info?).map(&.text)
    retry_infos.size.should eq(3)
    retry_infos.all? { |t| t.includes?("Retrying") }.should be_true
  end
end
