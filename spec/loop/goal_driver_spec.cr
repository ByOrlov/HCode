require "../spec_helper"
require "file_utils"

# Goal driver integration tests: verify run_goal_turn drives continuation
# turns when a goal is active, and stops when the model calls UpdateGoal.
# Uses the offline MockProvider so no network or API key is needed.
describe Hcode::Loop::Agent do
  it "drives continuation turns until the model marks the goal complete" do
    work_dir = File.join(Dir.tempdir, "hcode-goal-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      Hcode::Tools::Goal.service = Hcode::Tools::AgentGoalService.new

      # Step 1: model creates the goal (CreateGoal tool call), then ends turn.
      # Step 2 (continuation): model does some work, ends turn.
      # Step 3 (continuation): model calls UpdateGoal(complete), then ends turn.
      provider = Hcode::LLM::MockProvider.new([
        Hcode::LLM::MockStep.new(
          parts: [Hcode::LLM::ToolCallPart.new(
            "gc_1", "CreateGoal",
            %({"objective":"Fix all failing tests","completionCriterion":"crystal spec passes"})
          )] of Hcode::LLM::MessagePart,
          stop_reason: "tool_use",
        ),
        Hcode::LLM::MockStep.new(
          parts: [Hcode::LLM::TextPart.new("Goal created.")] of Hcode::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Goal created.",
        ),
        Hcode::LLM::MockStep.new(
          parts: [Hcode::LLM::TextPart.new("Working on the tests...")] of Hcode::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Working on the tests...",
        ),
        Hcode::LLM::MockStep.new(
          parts: [Hcode::LLM::ToolCallPart.new(
            "ug_1", "UpdateGoal", %({"status":"complete"})
          )] of Hcode::LLM::MessagePart,
          stop_reason: "tool_use",
        ),
        # After the tool result is returned, the model ends the turn.
        Hcode::LLM::MockStep.new(
          parts: [Hcode::LLM::TextPart.new("All done.")] of Hcode::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "All done.",
        ),
      ])

      memory = Hcode::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = Hcode::Tools::Registry.new
      tools.register(Hcode::Tools::CreateGoal.new)
      tools.register(Hcode::Tools::GetGoal.new)
      tools.register(Hcode::Tools::UpdateGoal.new)
      tools.register(Hcode::Tools::SetGoalBudget.new)

      permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
      agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of Hcode::Loop::Event
      agent.run_goal_turn("Fix all failing tests", nil) { |e| events << e }

      # After completion, the goal record is cleared.
      (Hcode::Tools::Goal.service || raise "Goal.service not initialized").get_goal.should be_nil

      # Three turns ran: initial + 2 continuations.
      turn_ends = events.count { |e| e.type.turn_end? }
      turn_ends.should eq(3)
    ensure
      Hcode::Tools::Goal.service = nil
      FileUtils.rm_rf(work_dir) if work_dir
    end
  end

  it "blocks the goal when a turn budget is reached" do
    work_dir = File.join(Dir.tempdir, "hcode-goal-budget-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      service = Hcode::Tools::AgentGoalService.new
      Hcode::Tools::Goal.service = service

      # Step 1: CreateGoal + SetGoalBudget(turns=1).
      provider = Hcode::LLM::MockProvider.new([
        Hcode::LLM::MockStep.new(
          parts: [
            Hcode::LLM::ToolCallPart.new(
              "gc_1", "CreateGoal",
              %({"objective":"Small task"})
            ),
            Hcode::LLM::ToolCallPart.new(
              "sb_1", "SetGoalBudget", %({"value":1,"unit":"turns"})
            ),
          ] of Hcode::LLM::MessagePart,
          stop_reason: "tool_use",
        ),
        # Step 2: continuation — model does work, doesn't call UpdateGoal.
        Hcode::LLM::MockStep.new(
          parts: [Hcode::LLM::TextPart.new("Doing work...")] of Hcode::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Doing work...",
        ),
      ])

      memory = Hcode::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = Hcode::Tools::Registry.new
      tools.register(Hcode::Tools::CreateGoal.new)
      tools.register(Hcode::Tools::GetGoal.new)
      tools.register(Hcode::Tools::UpdateGoal.new)
      tools.register(Hcode::Tools::SetGoalBudget.new)

      permission = Hcode::Permission::Manager.new(Hcode::Permission::Mode::Yolo)
      agent = Hcode::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of Hcode::Loop::Event
      agent.run_goal_turn("do it", nil) { |e| events << e }

      goal = service.get_goal
      goal.should_not be_nil
      if (g = goal)
        g.status.blocked?.should be_true
        (g.terminal_reason || "").should contain("budget")
      end
    ensure
      Hcode::Tools::Goal.service = nil
      FileUtils.rm_rf(work_dir) if work_dir
    end
  end
end
