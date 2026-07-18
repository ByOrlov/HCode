require "../spec_helper"

# Тестовый runner: возвращает фиксированные результаты по спецификации.
# Не запускает реальных субагентов — нужен только для проверки контракта тула.
private class FakeRunner
  include Hcode::Tools::SwarmRunner

  getter calls = [] of {Hcode::Tools::AgentSwarmSpec, Hcode::Tools::SwarmRunContext}

  def initialize(@behaviour : Hcode::Tools::AgentSwarmSpec -> Hcode::Tools::SwarmRunResult)
  end

  def call(spec : Hcode::Tools::AgentSwarmSpec, ctx : Hcode::Tools::SwarmRunContext) : Hcode::Tools::SwarmRunResult
    @calls << {spec, ctx}
    @behaviour.call(spec)
  end
end

describe Hcode::Tools::AgentSwarm do
  after_each do
    Hcode::Tools::AgentSwarm.runner = nil
  end

  it "exposes the JS-name and identical schema" do
    swarm = Hcode::Tools::AgentSwarm.new
    swarm.name.should eq("AgentSwarm")
    swarm.description.should contain("{{item}}")
    swarm.description.should contain("AgentSwarm supports up to 128 subagents")

    props = swarm.parameters["properties"].as_h
    props.has_key?("description").should be_true
    props.has_key?("subagent_type").should be_true
    props.has_key?("prompt_template").should be_true
    props.has_key?("items").should be_true
    props.has_key?("resume_agent_ids").should be_true

    items = props["items"].as_h
    items["maxItems"].as_i.should eq(128)
    swarm.parameters["additionalProperties"].as_bool.should be_false
  end

  it "fails when fewer than 2 items and no resume_agent_ids" do
    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "test swarm",
      "prompt_template": "do {{item}}",
      "items": ["only one"]
    })))
    result.is_error.should be_true
    result.content.should contain("at least 2 items")
  end

  it "fails when items provided but prompt_template is missing" do
    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "test swarm",
      "items": ["a", "b"]
    })))
    result.is_error.should be_true
    result.content.should contain("prompt_template is required")
  end

  it "fails when prompt_template is missing the {{item}} placeholder" do
    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "test swarm",
      "prompt_template": "no placeholder here",
      "items": ["a", "b"]
    })))
    result.is_error.should be_true
    result.content.should contain("must include the {{item}}")
  end

  it "fails on duplicate expanded prompts" do
    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "test swarm",
      "prompt_template": "static prompt about {{item}}",
      "items": ["x", "x"]
    })))
    result.is_error.should be_true
    result.content.should contain("Duplicate subagent prompts")
    result.content.should contain("items 1 and 2")
  end

  it "returns a clear error when no subagent runtime is registered" do
    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "test swarm",
      "prompt_template": "review {{item}}",
      "items": ["a.ts", "b.ts"]
    })))
    result.is_error.should be_true
    result.content.should contain("no subagent runtime is registered")
  end

  it "renders agent_swarm_result XML for successful runs" do
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      Hcode::Tools::SwarmRunResult.new(
        spec: spec,
        status: Hcode::Tools::SwarmStatus::Completed,
        agent_id: "agent-#{spec.index}",
        result: "summary for #{spec.item || spec.prompt}",
      )
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "review PRs",
      "prompt_template": "Review {{item}} for regressions.",
      "items": ["src/a.ts", "src/b.ts"]
    })))
    result.is_error.should be_false
    result.content.should contain("<agent_swarm_result>")
    result.content.should contain("</agent_swarm_result>")
    result.content.should contain("<summary>completed: 2</summary>")
    result.content.should contain(%(outcome="completed"))
    result.content.should contain(%(agent_id="agent-1"))
    result.content.should contain(%(item="src/a.ts"))
    result.content.should contain("summary for src/a.ts")
    # No failures → no resume_hint.
    result.content.should_not contain("<resume_hint>")
  end

  it "renders resume_hint when at least one result has failures and an agent_id" do
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      status = spec.index == 1 ? Hcode::Tools::SwarmStatus::Failed : Hcode::Tools::SwarmStatus::Completed
      Hcode::Tools::SwarmRunResult.new(
        spec: spec,
        status: status,
        agent_id: "agent-#{spec.index}",
        error: spec.index == 1 ? "boom" : nil,
        result: spec.index == 1 ? nil : "ok",
      )
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "review PRs",
      "prompt_template": "Review {{item}}.",
      "items": ["a", "b"]
    })))
    result.is_error.should be_false
    result.content.should contain("<resume_hint>")
    result.content.should contain("completed: 1")
    result.content.should contain("failed: 1")
    result.content.should contain(%(outcome="failed">boom))
  end

  it "renders aborted count in the summary" do
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      st = spec.index == 1 ? Hcode::Tools::SwarmStatus::Aborted : Hcode::Tools::SwarmStatus::Completed
      Hcode::Tools::SwarmRunResult.new(spec: spec, status: st, agent_id: "a-#{spec.index}",
        result: st.completed? ? "ok" : nil, error: st.completed? ? nil : "aborted")
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "x",
      "prompt_template": "do {{item}}",
      "items": ["a", "b"]
    })))
    result.content.should contain("completed: 1")
    result.content.should contain("aborted: 1")
    result.content.should contain(%(outcome="aborted"))
  end

  it "escapes XML-special characters in the item attribute" do
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      Hcode::Tools::SwarmRunResult.new(spec: spec, status: Hcode::Tools::SwarmStatus::Completed,
        agent_id: "x", result: "ok")
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%q({
      "description": "x",
      "prompt_template": "do {{item}}",
      "items": ["a<b>&c\"x", "normal"]
    })))
    result.content.should contain(%(item="a&lt;b&gt;&amp;c&quot;x"))
  end

  it "accepts resume_agent_ids alone (single-resume is allowed)" do
    calls = [] of Hcode::Tools::AgentSwarmSpec
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      calls << spec
      Hcode::Tools::SwarmRunResult.new(spec: spec, status: Hcode::Tools::SwarmStatus::Completed,
        agent_id: spec.as(Hcode::Tools::ResumeSpec).agent_id, result: "resumed")
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "resume one",
      "resume_agent_ids": { "agent-42": "continue" }
    })))
    result.is_error.should be_false
    result.content.should contain(%(mode="resume"))
    result.content.should contain(%(agent_id="agent-42"))
    result.content.should contain("resumed")
    calls.size.should eq(1)
    calls.first.is_a?(Hcode::Tools::ResumeSpec).should be_true
  end

  it "runs resumed specs before item specs and keeps 1-based indexing" do
    calls = [] of Hcode::Tools::AgentSwarmSpec
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      calls << spec
      Hcode::Tools::SwarmRunResult.new(spec: spec, status: Hcode::Tools::SwarmStatus::Completed,
        agent_id: "x-#{spec.index}", result: "ok")
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "mixed",
      "prompt_template": "do {{item}}",
      "items": ["one", "two"],
      "resume_agent_ids": { "r-1": "go", "r-2": "go2" }
    })))
    result.is_error.should be_false
    calls.size.should eq(4)
    # First two are resumes, next two are spawns, indices 1..4.
    calls[0].is_a?(Hcode::Tools::ResumeSpec).should be_true
    calls[1].is_a?(Hcode::Tools::ResumeSpec).should be_true
    calls[2].is_a?(Hcode::Tools::SpawnSpec).should be_true
    calls[3].is_a?(Hcode::Tools::SpawnSpec).should be_true
    calls.map(&.index).should eq([1, 2, 3, 4])
  end

  it "renders state attribute when the runner reports one" do
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      Hcode::Tools::SwarmRunResult.new(spec: spec, status: Hcode::Tools::SwarmStatus::Failed,
        agent_id: "x", state: "not_started", error: "queue overflow")
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    result = swarm.execute(JSON.parse(%({
      "description": "x",
      "prompt_template": "do {{item}}",
      "items": ["a", "b"]
    })))
    result.content.should contain(%(state="not_started"))
  end

  it "uses default subagent_type when omitted" do
    seen = [] of String
    runner = FakeRunner.new(->(spec : Hcode::Tools::AgentSwarmSpec) do
      Hcode::Tools::SwarmRunResult.new(spec: spec, status: Hcode::Tools::SwarmStatus::Completed,
        agent_id: "x", result: "ok")
    end)
    Hcode::Tools::AgentSwarm.runner = runner

    swarm = Hcode::Tools::AgentSwarm.new
    swarm.execute(JSON.parse(%({
      "description": "x",
      "prompt_template": "do {{item}}",
      "items": ["a", "b"]
    })))
    runner.calls.size.should eq(2)
    runner.calls.each do |(spec, ctx)|
      ctx.profile_name.should eq("coder")
    end
  end
end
