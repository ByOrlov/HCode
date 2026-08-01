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
    memory.messages.last.text.should eq("all done here")
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
    memory.messages.last.text.should eq("first")

    agent.swap_provider!(second)
    agent.provider.should be(second)

    agent.run_turn("turn two", nil) { }
    memory.messages.last.text.should eq("second")
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
    agent.context.history.last.message.text.should eq("a side note")
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

  # End-to-end plan-mode flow: enter → blocked Write → exit. Verifies the
  # wiring between Permission guard, the Agent's plan reminder injection, and
  # the plan-mode service lifecycle — the piece that was missing before this
  # change (EnterPlanMode/ExitPlanMode existed but were dead code).
  it "enforces plan mode: Write is blocked and a reminder is injected" do
    dir = File.join(Dir.tempdir, "hcode-plan-flow-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    plan_path = File.join(dir, "plan.md")

    # Mock provider that records every message list it receives, so the test
    # can assert the plan-mode reminder was present on some step even though
    # `prune_injections` removes it on the next step.
    captured_messages = [] of Array(Hcode::LLM::Message)
    recording_provider = Hcode::LLM::MockProvider.new([
      # Step 1: enter plan mode.
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new("c1", "EnterPlanMode", %({}))] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 2: attempt a Write (should be blocked by the guard).
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new(
          "c2", "Write", %({"path":"/tmp/hcode-plan-block.txt","content":"x"})
        )] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 3: write the plan to the plan file (allowed).
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new(
          "c3", "Write", %({"path":#{plan_path.inspect},"content":"## Plan\\n\\nDo it."})
        )] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 4: exit plan mode (auto-approved).
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new("c4", "ExitPlanMode", %({}))] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 5: done.
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("finished")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "finished",
      ),
    ])

    service = Hcode::Tools::AgentPlanService.new(dir, "main", plan_path)
    Hcode::Tools::PlanMode.plan_service = service
    Hcode::Tools::PlanMode.permission_mode = Hcode::Tools::PermissionModeRef.new(auto: true)
    Hcode::Tools::PlanMode.plan_review_service = nil

    begin
      # Build a provider subclass that records messages before delegating.
      provider = RecordingProvider.new(recording_provider, captured_messages)

      memory = Hcode::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = Hcode::Tools::Registry.new
      tools.register(Hcode::Tools::EnterPlanMode.new)
      tools.register(Hcode::Tools::ExitPlanMode.new)
      tools.register(Hcode::Tools::Write.new(dir))
      permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
      agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of Hcode::Loop::Event
      agent.run_turn("plan something", nil) { |e| events << e }

      tool_results = events.select(&.type.tool_result?).map(&.text)
      # The second tool call (Write to a non-plan path) must be blocked by the
      # plan-mode guard — the guard emits an Info event with its message and
      # the tool batch reports "Permission denied".
      blocked_result = tool_results.select(&.includes?("Permission denied for Write"))
      blocked_result.should_not be_empty
      guard_infos = events.select(&.type.info?).map(&.text)
      guard_infos.any?(&.includes?("Plan mode is active")).should be_true

      # The plan file was writable (step 3 succeeded) and ExitPlanMode reported
      # auto-approval (step 4).
      exit_result = tool_results.find(&.includes?("Exited plan mode"))
      exit_result.should_not be_nil
      exit_result.not_nil!.includes?("auto-approved").should be_true

      # The forbidden file was never created.
      File.exists?("/tmp/hcode-plan-block.txt").should be_false

      # Plan-mode reminder was injected into the messages sent to the LLM on at
      # least one step while plan mode was active.
      reminders = captured_messages.flatten.select(&.text.includes?("Plan mode is active"))
      reminders.should_not be_empty

      # Plan mode is off after exit.
      service.status.should be_nil
    ensure
      Hcode::Tools::PlanMode.plan_service = nil
      Hcode::Tools::PlanMode.permission_mode = nil
      FileUtils.rm_rf(dir)
      File.delete("/tmp/hcode-plan-block.txt") rescue nil
    end
  end

  # The loop-level exception interceptor: when a tool raises an unexpected
  # Crystal exception mid-turn, the loop catches it, emits an Exception event
  # (so the TUI can render it red), then re-raises. Crucially, turn_end is
  # always emitted so the TUI resets to idle and the user can keep typing —
  # instead of the interface crumbling.
  it "surfaces a tool exception as an Exception event and still emits turn_end" do
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new("c1", "Boom", %({}))] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
    ])
    memory = Hcode::Context::Memory.new
    memory.max_context_tokens = 131_072
    tools = Hcode::Tools::Registry.new
    tools.register(BoomTool.new)
    permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
    agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of Hcode::Loop::Event
    # The exception is re-raised so callers keep their failure contract.
    expect_raises(Exception, "kaboom from BoomTool") do
      agent.run_turn("trigger boom", nil) { |e| events << e }
    end

    # An Exception event was emitted with the formatted exception text.
    exc_events = events.select(&.type.exception?)
    exc_events.size.should eq(1)
    exc_events.first.text.should contain("BoomTool")
    exc_events.first.text.should contain("kaboom from BoomTool")

    # turn_end was still emitted (in the ensure block), so the TUI resets.
    turn_ends = events.select(&.type.turn_end?)
    turn_ends.size.should eq(1)

    # turn_end comes after the Exception event in the stream.
    exc_idx = events.index(&.type.exception?).not_nil!
    te_idx = events.index(&.type.turn_end?).not_nil!
    te_idx.should be > exc_idx

    # The agent is no longer busy after the turn.
    agent.busy?.should be_false
  end
end

# Mock provider wrapper that records every message list handed to `chat`,
# then delegates to the underlying MockProvider's script. Used by the plan-mode
# integration test to assert the plan-mode reminder injection reached the LLM.
private class RecordingProvider < Hcode::LLM::Provider
  @step : Int32 = 0

  def initialize(@inner : Hcode::LLM::MockProvider, @captured : Array(Array(Hcode::LLM::Message)))
  end

  def name : String
    "recording"
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
    @captured << messages.map(&.dup)
    @inner.chat(messages, tools, system_prompt, aborted?) { |p| block.call(p) }
  end
end

# Test tool that raises an unexpected Crystal exception on every call. Used to
# verify the loop-level exception interceptor: the exception is surfaced as an
# Exception event and turn_end still fires so the TUI does not crumble.
private class BoomTool < Hcode::Tools::Tool
  def name : String
    "Boom"
  end

  def description : String
    "Always raises an exception — for tests."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object","properties":{},"additionalProperties":false}))
  end

  def execute(input : JSON::Any) : Hcode::Tools::ToolResult
    raise Exception.new("kaboom from BoomTool")
  end
end
