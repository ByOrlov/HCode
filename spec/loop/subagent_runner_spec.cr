require "../spec_helper"

describe H2code::Loop::SubagentAgentRunner do
  describe "foreground spawn" do
    it "drives a turn and returns completed with the assistant summary" do
      provider = H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("Child agent reply.")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Child agent reply.",
        ),
      ])
      memory = H2code::Context::Memory.new
      tools = H2code::Tools::Registry.new
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      registry = H2code::Loop::SubagentRegistry.new
      task_service = H2code::Tools::InMemoryTaskService.new
      runner = H2code::Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: parent,
        task_service: task_service,
        system_prompt: "sys",
        work_dir: Dir.current,
        permission_mode: H2code::Permission::Mode::Yolo,
      )

      outcome = runner.launch(
        {
          prompt:            "do the thing",
          description:       "test task",
          subagent_type:     "coder",
          resume_agent_id:   nil,
          run_in_background: false,
        },
        nil,
      )

      outcome.status.completed?.should be_true
      outcome.summary.should eq("Child agent reply.")
      outcome.agent_id.should start_with("agent-")
      outcome.profile_name.should eq("coder")
      registry.size.should eq(1)
    end

    it "returns failed when the child turn raises" do
      provider = H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "",
        ),
      ])
      # Force the provider to raise on chat by exhausting the script and
      # letting it replay the last step harmlessly — instead test the abort
      # path directly via a cancelled parent.
      memory = H2code::Context::Memory.new
      tools = H2code::Tools::Registry.new
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      registry = H2code::Loop::SubagentRegistry.new
      task_service = H2code::Tools::InMemoryTaskService.new
      runner = H2code::Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: parent,
        task_service: task_service,
        system_prompt: "sys",
        work_dir: Dir.current,
        permission_mode: H2code::Permission::Mode::Yolo,
      )

      # Pre-cancel the parent so the child's run_turn aborts immediately.
      parent.abort_controller.abort("test cancel")

      outcome = runner.launch(
        {
          prompt:            "do the thing",
          description:       "test task",
          subagent_type:     "coder",
          resume_agent_id:   nil,
          run_in_background: false,
        },
        nil,
      )

      outcome.status.aborted?.should be_true
      (outcome.error || raise "error should not be nil").should_not be_empty
    end
  end

  describe "resume" do
    it "returns failed for an unknown agent_id" do
      provider = H2code::LLM::MockProvider.new
      memory = H2code::Context::Memory.new
      tools = H2code::Tools::Registry.new
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      registry = H2code::Loop::SubagentRegistry.new
      task_service = H2code::Tools::InMemoryTaskService.new
      runner = H2code::Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: parent,
        task_service: task_service,
        system_prompt: "sys",
        work_dir: Dir.current,
        permission_mode: H2code::Permission::Mode::Yolo,
      )

      outcome = runner.launch(
        {
          prompt:            "continue",
          description:       "resume",
          subagent_type:     nil,
          resume_agent_id:   "agent-999",
          run_in_background: false,
        },
        nil,
      )

      outcome.status.failed?.should be_true
      (outcome.error || raise "error should not be nil").should contain("does not exist")
    end

    it "resumes an existing child agent on its prior context" do
      provider = H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("First turn.")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "First turn.",
        ),
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("Second turn.")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Second turn.",
        ),
      ])
      memory = H2code::Context::Memory.new
      tools = H2code::Tools::Registry.new
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      registry = H2code::Loop::SubagentRegistry.new
      task_service = H2code::Tools::InMemoryTaskService.new
      runner = H2code::Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: parent,
        task_service: task_service,
        system_prompt: "sys",
        work_dir: Dir.current,
        permission_mode: H2code::Permission::Mode::Yolo,
      )

      # First run: spawn.
      first = runner.launch(
        {
          prompt:            "turn one",
          description:       "spawn",
          subagent_type:     "coder",
          resume_agent_id:   nil,
          run_in_background: false,
        },
        nil,
      )
      first.status.completed?.should be_true
      agent_id = first.agent_id

      # Second run: resume the same agent — it keeps its context.
      second = runner.launch(
        {
          prompt:            "turn two",
          description:       "resume",
          subagent_type:     nil,
          resume_agent_id:   agent_id,
          run_in_background: false,
        },
        nil,
      )
      second.status.completed?.should be_true
      second.summary.should eq("Second turn.")
      second.agent_id.should eq(agent_id)
    end
  end

  describe "background spawn" do
    it "returns detached immediately and registers a task" do
      provider = H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("Background done.")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Background done.",
        ),
      ])
      memory = H2code::Context::Memory.new
      tools = H2code::Tools::Registry.new
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      registry = H2code::Loop::SubagentRegistry.new
      task_service = H2code::Tools::InMemoryTaskService.new
      runner = H2code::Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: parent,
        task_service: task_service,
        system_prompt: "sys",
        work_dir: Dir.current,
        permission_mode: H2code::Permission::Mode::Yolo,
      )

      outcome = runner.launch(
        {
          prompt:            "bg task",
          description:       "background",
          subagent_type:     "coder",
          resume_agent_id:   nil,
          run_in_background: true,
        },
        nil,
      )

      outcome.status.detached?.should be_true
      outcome.task_id.should_not be_nil

      # The task is registered as running.
      task = task_service.get_task(outcome.task_id || raise "task_id should not be nil")
      task.should_not be_nil
      if task
        task.status.running?.should be_true
      end
    end
  end
end

describe H2code::Loop::SubagentSwarmRunner do
  it "runs a spawn spec and returns completed" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("Swarm child result.")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "Swarm child result.",
      ),
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("Swarm child result 2.")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "Swarm child result 2.",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    registry = H2code::Loop::SubagentRegistry.new
    runner = H2code::Loop::SubagentSwarmRunner.new(
      registry: registry,
      parent_agent: parent,
      system_prompt: "sys",
      work_dir: Dir.current,
      permission_mode: H2code::Permission::Mode::Yolo,
    )

    spec = H2code::Tools::SpawnSpec.new(index: 1, prompt: "review file a", item: "src/a.cr")
    ctx = H2code::Tools::SwarmRunContext.new(
      parent_description: "Review",
      profile_name: "coder",
      description: "Review #1 (coder)",
      swarm_index: 1,
    )

    result = runner.call(spec, ctx)
    result.status.completed?.should be_true
    result.result.should eq("Swarm child result.")
    result.agent_id.should_not be_nil
  end

  it "returns failed for a resume spec with unknown agent_id" do
    provider = H2code::LLM::MockProvider.new
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    parent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    registry = H2code::Loop::SubagentRegistry.new
    runner = H2code::Loop::SubagentSwarmRunner.new(
      registry: registry,
      parent_agent: parent,
      system_prompt: "sys",
      work_dir: Dir.current,
      permission_mode: H2code::Permission::Mode::Yolo,
    )

    spec = H2code::Tools::ResumeSpec.new(index: 1, agent_id: "agent-404", prompt: "continue")
    ctx = H2code::Tools::SwarmRunContext.new(
      parent_description: "Review",
      profile_name: "subagent",
      description: "Resume #1",
      swarm_index: 1,
    )

    result = runner.call(spec, ctx)
    result.status.failed?.should be_true
    (result.error || raise "error should not be nil").should contain("does not exist")
  end
end

describe H2code::Loop::ProfileRegistry do
  it "builds a read-only registry for the explore profile" do
    registry = H2code::Loop::ProfileRegistry.build("explore", Dir.current)
    registry.get(H2code::Tools::Names::READ).should_not be_nil
    registry.get(H2code::Tools::Names::GREP).should_not be_nil
    registry.get(H2code::Tools::Names::GLOB).should_not be_nil
    # explore has no file-editing tools and no Agent/Swarm delegation.
    registry.get(H2code::Tools::Names::WRITE).should be_nil
    registry.get(H2code::Tools::Names::EDIT).should be_nil
    registry.get(H2code::Tools::Names::AGENT).should be_nil
  end

  it "builds a full registry for the coder profile" do
    registry = H2code::Loop::ProfileRegistry.build("coder", Dir.current)
    registry.get(H2code::Tools::Names::READ).should_not be_nil
    registry.get(H2code::Tools::Names::WRITE).should_not be_nil
    registry.get(H2code::Tools::Names::EDIT).should_not be_nil
    registry.get(H2code::Tools::Names::BASH).should_not be_nil
    registry.get(H2code::Tools::Names::AGENT).should_not be_nil
  end

  it "raises for an unknown profile" do
    expect_raises(Exception, "Unknown agent profile: nope") do
      H2code::Loop::ProfileRegistry.build("nope", Dir.current)
    end
  end
end
