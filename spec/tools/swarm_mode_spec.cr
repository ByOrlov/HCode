require "../spec_helper"
require "../../src/tools/swarm_mode"
require "../../src/loop/agent"

describe Hcode::Tools::SwarmModeService do
  it "starts inactive and toggles with enter/exit" do
    svc = Hcode::Tools::SwarmModeService.new
    svc.active?.should be_false
    svc.trigger.should be_nil

    svc.enter(Hcode::Tools::SwarmTrigger::Manual)
    svc.active?.should be_true
    svc.trigger.should eq(Hcode::Tools::SwarmTrigger::Manual)

    svc.exit
    svc.active?.should be_false
    svc.trigger.should be_nil
  end

  it "auto-exits task and tool triggers but keeps manual on" do
    task_svc = Hcode::Tools::SwarmModeService.new
    task_svc.enter(Hcode::Tools::SwarmTrigger::Task)
    task_svc.auto_exit!.should be_true
    task_svc.active?.should be_false

    tool_svc = Hcode::Tools::SwarmModeService.new
    tool_svc.enter(Hcode::Tools::SwarmTrigger::Tool)
    tool_svc.auto_exit!.should be_true
    tool_svc.active?.should be_false

    manual_svc = Hcode::Tools::SwarmModeService.new
    manual_svc.enter(Hcode::Tools::SwarmTrigger::Manual)
    manual_svc.auto_exit!.should be_false
    manual_svc.active?.should be_true
  end

  it "auto_exit! is a no-op when inactive" do
    svc = Hcode::Tools::SwarmModeService.new
    svc.auto_exit!.should be_false
  end
end

describe "swarm mode injection in Loop::Agent" do
  it "injects the enter-reminder while active and auto-exits a task trigger at turn end" do
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

    svc = Hcode::Tools::SwarmModeService.new
    Hcode::Tools::SwarmMode.service = svc
    svc.enter(Hcode::Tools::SwarmTrigger::Task)

    begin
      agent.run_turn("swarm this", nil) { }
    ensure
      Hcode::Tools::SwarmMode.service = nil
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

    Hcode::Tools::SwarmMode.service = Hcode::Tools::SwarmModeService.new
    begin
      agent.run_turn("plain turn", nil) { }
    ensure
      Hcode::Tools::SwarmMode.service = nil
    end

    injected = memory.history.select(&.origin.injection?).map(&.message.text)
    injected.any?(&.includes?("Swarm Mode")).should be_false
  end
end
