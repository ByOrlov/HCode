require "../spec_helper"
require "../../src/tools/agent"

# Тестовый runner: позволяет управлять исходом запуска субагента.
private class FakeRunner < Hcode::Tools::AgentRunner
  getter calls = [] of Hcode::Tools::AgentLaunchSpec
  property behaviour : Hcode::Tools::AgentLaunchSpec -> Hcode::Tools::AgentRunOutcome

  def initialize(@behaviour : Hcode::Tools::AgentLaunchSpec -> Hcode::Tools::AgentRunOutcome)
  end

  def launch(spec : Hcode::Tools::AgentLaunchSpec, signal : Hcode::Tools::AbortController?) : Hcode::Tools::AgentRunOutcome
    @calls << spec
    @behaviour.call(spec)
  end
end

describe Hcode::Tools::Agent do
  after_each do
    Hcode::Tools::Agent.runner = nil
    Hcode::Tools::Agent.background_enabled = false
  end

  it "exposes the JS-name and identical schema" do
    agent = Hcode::Tools::Agent.new
    agent.name.should eq("Agent")
    agent.description.should contain("Launch a subagent")
    agent.description.should contain("agent")
    agent.description.should contain("coder")
    agent.description.should contain("explore")

    props = agent.parameters["properties"].as_h
    props.has_key?("prompt").should be_true
    props.has_key?("description").should be_true
    props.has_key?("subagent_type").should be_true
    props.has_key?("resume").should be_true
    props.has_key?("run_in_background").should be_true

    required = agent.parameters["required"].as_a.map(&.as_s)
    required.should eq(["prompt", "description"])
    agent.parameters["additionalProperties"].as_bool.should be_false
  end

  it "toggles background paragraph based on background_enabled flag" do
    agent = Hcode::Tools::Agent.new
    agent.description.should contain("Background agent execution is disabled")

    Hcode::Tools::Agent.background_enabled = true
    agent.description.should contain("run_in_background=true")
    agent.description.should contain("The completion arrives in a later turn")
  end

  it "returns a clear error when no subagent runtime is registered" do
    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "do something",
      "description": "test"
    })))
    result.is_error?.should be_true
    result.content.should contain("no subagent runtime is registered")
  end

  it "rejects resume + subagent_type together" do
    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test",
      "resume": "agent-1",
      "subagent_type": "coder"
    })))
    result.is_error?.should be_true
    result.content.should contain("Cannot set subagent_type when resuming")
  end

  it "rejects run_in_background=true when background is disabled" do
    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test",
      "run_in_background": true
    })))
    result.is_error?.should be_true
    result.content.should contain("Background agent execution is not available")
  end

  it "rejects unknown subagent_type" do
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      Hcode::Tools::AgentRunOutcome.new(
        agent_id: "x", profile_name: "coder",
        status: Hcode::Tools::AgentRunStatus::Completed, summary: "ok"
      )
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test",
      "subagent_type": "unknown_profile"
    })))
    result.is_error?.should be_true
    result.content.should contain("Unknown agent type")
  end

  it "defaults subagent_type to coder when omitted" do
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      Hcode::Tools::AgentRunOutcome.new(
        agent_id: "x", profile_name: s[:subagent_type] || "coder",
        status: Hcode::Tools::AgentRunStatus::Completed, summary: "ok"
      )
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test"
    })))
    result.is_error?.should be_false
    runner.calls.first[:subagent_type].should eq("coder")
    result.content.should contain("actual_subagent_type: coder")
    result.content.should contain("status: completed")
  end

  it "renders foreground success format" do
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      Hcode::Tools::AgentRunOutcome.new(
        agent_id: "agent-42",
        profile_name: "coder",
        status: Hcode::Tools::AgentRunStatus::Completed,
        summary: "Refactored foo.cr and added tests."
      )
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "refactor"
    })))
    result.is_error?.should be_false
    result.content.should contain("agent_id: agent-42")
    result.content.should contain("actual_subagent_type: coder")
    result.content.should contain("status: completed")
    result.content.should contain("Refactored foo.cr and added tests.")
  end

  it "renders foreground failure with resume_hint on timeout" do
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      Hcode::Tools::AgentRunOutcome.new(
        agent_id: "agent-9",
        profile_name: "coder",
        status: Hcode::Tools::AgentRunStatus::Failed,
        error: "Agent timed out after 2 hours.",
        timed_out: true
      )
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test"
    })))
    result.is_error?.should be_true
    result.content.should contain("agent_id: agent-9")
    result.content.should contain("status: failed")
    result.content.should contain("subagent error: Agent timed out after 2 hours.")
    result.content.should contain("resume_hint:")
    result.content.should contain("Agent(resume=\"agent-9\"")
  end

  it "renders foreground failure without resume_hint when not timed out" do
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      Hcode::Tools::AgentRunOutcome.new(
        agent_id: "agent-9",
        profile_name: "coder",
        status: Hcode::Tools::AgentRunStatus::Failed,
        error: "boom"
      )
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test"
    })))
    result.is_error?.should be_true
    result.content.should contain("subagent error: boom")
    result.content.should_not contain("resume_hint:")
  end

  it "renders detached (background) result format" do
    Hcode::Tools::Agent.background_enabled = true
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      Hcode::Tools::AgentRunOutcome.new(
        agent_id: "agent-100",
        profile_name: "coder",
        status: Hcode::Tools::AgentRunStatus::Detached,
        description: "long-running job",
        task_id: "task-5"
      )
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "long-running job",
      "run_in_background": true
    })))
    result.is_error?.should be_false
    result.content.should contain("task_id: task-5")
    result.content.should contain("status: running")
    result.content.should contain("agent_id: agent-100")
    result.content.should contain("actual_subagent_type: coder")
    result.content.should contain("automatic_notification: true")
    result.content.should contain("description: long-running job")
    result.content.should contain("next_step:")
    result.content.should contain("resume_hint:")
  end

  it "renders timeout description in hours/minutes/seconds" do
    agent = Hcode::Tools::Agent.new
    agent.format_subagent_timeout_description(7_200_000).should eq("2 hours")
    agent.format_subagent_timeout_description(3_600_000).should eq("1 hour")
    agent.format_subagent_timeout_description(60_000).should eq("1 minute")
    agent.format_subagent_timeout_description(120_000).should eq("2 minutes")
    agent.format_subagent_timeout_description(1000).should eq("1 second")
    agent.format_subagent_timeout_description(45_678).should eq("45678 ms")
  end

  it "wraps runner exceptions into subagent error" do
    runner = FakeRunner.new(->(s : Hcode::Tools::AgentLaunchSpec) do
      raise "boom"
    end)
    Hcode::Tools::Agent.runner = runner

    agent = Hcode::Tools::Agent.new
    result = agent.execute(JSON.parse(%({
      "prompt": "go",
      "description": "test"
    })))
    result.is_error?.should be_true
    result.content.should contain("subagent error: boom")
  end
end
