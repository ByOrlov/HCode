require "../spec_helper"
require "../../src/tools/swarm_mode"
require "../../src/loop/agent"

describe H2code::Tools::SwarmModeService do
  it "starts inactive and toggles with enter/exit" do
    svc = H2code::Tools::SwarmModeService.new
    svc.active?.should be_false
    svc.trigger.should be_nil

    svc.enter(H2code::Tools::SwarmTrigger::Manual)
    svc.active?.should be_true
    svc.trigger.should eq(H2code::Tools::SwarmTrigger::Manual)

    svc.exit
    svc.active?.should be_false
    svc.trigger.should be_nil
  end

  it "auto-exits task and tool triggers but keeps manual on" do
    task_svc = H2code::Tools::SwarmModeService.new
    task_svc.enter(H2code::Tools::SwarmTrigger::Task)
    task_svc.auto_exit!.should be_true
    task_svc.active?.should be_false

    tool_svc = H2code::Tools::SwarmModeService.new
    tool_svc.enter(H2code::Tools::SwarmTrigger::Tool)
    tool_svc.auto_exit!.should be_true
    tool_svc.active?.should be_false

    manual_svc = H2code::Tools::SwarmModeService.new
    manual_svc.enter(H2code::Tools::SwarmTrigger::Manual)
    manual_svc.auto_exit!.should be_false
    manual_svc.active?.should be_true
  end

  it "auto_exit! is a no-op when inactive" do
    svc = H2code::Tools::SwarmModeService.new
    svc.auto_exit!.should be_false
  end
end

describe "swarm mode injection in Loop::Agent" do
  it "injects the enter-reminder while active and auto-exits a task trigger at turn end" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("ok")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ok",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    svc = H2code::Tools::SwarmModeService.new
    H2code::Tools::SwarmMode.service = svc
    svc.enter(H2code::Tools::SwarmTrigger::Task)

    begin
      agent.run_turn("swarm this", nil) { }
    ensure
      H2code::Tools::SwarmMode.service = nil
    end

    # The enter-reminder was injected during the step…
    injected = memory.history.select(&.origin.injection?).map(&.message.text)
    injected.any?(&.includes?("Swarm Mode")).should be_true
    # …and the exit-reminder is left behind after the task-trigger auto-exit.
    injected.any?(&.includes?("Swarm Mode Ended")).should be_true
    # The mode itself is now off.
    svc.active?.should be_false
  end

  it "does not inject a swarm reminder when the mode is off" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("ok")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ok",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    H2code::Tools::SwarmMode.service = H2code::Tools::SwarmModeService.new
    begin
      agent.run_turn("plain turn", nil) { }
    ensure
      H2code::Tools::SwarmMode.service = nil
    end

    injected = memory.history.select(&.origin.injection?).map(&.message.text)
    injected.any?(&.includes?("Swarm Mode")).should be_false
  end
end
