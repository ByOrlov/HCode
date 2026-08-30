require "../spec_helper"
require "file_utils"

# Goal driver integration tests: verify run_goal_turn drives continuation
# turns when a goal is active, and stops when the model calls UpdateGoal.
# Uses the offline MockProvider so no network or API key is needed.
describe H2code::Loop::Agent do
  it "drives continuation turns until the model marks the goal complete" do
    work_dir = File.join(Dir.tempdir, "h2code-goal-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      H2code::Tools::Goal.service = H2code::Tools::AgentGoalService.new

      # Step 1: model creates the goal (CreateGoal tool call), then ends turn.
      # Step 2 (continuation): model does some work, ends turn.
      # Step 3 (continuation): model calls UpdateGoal(complete), then ends turn.
      provider = H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::ToolCallPart.new(
            "gc_1", H2code::Tools::Names::CREATE_GOAL,
            %({"objective":"Fix all failing tests","completionCriterion":"crystal spec passes"})
          )] of H2code::LLM::MessagePart,
          stop_reason: "tool_use",
        ),
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("Goal created.")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Goal created.",
        ),
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("Working on the tests...")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Working on the tests...",
        ),
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::ToolCallPart.new(
            "ug_1", H2code::Tools::Names::UPDATE_GOAL, %({"status":"complete"})
          )] of H2code::LLM::MessagePart,
          stop_reason: "tool_use",
        ),
        # After the tool result is returned, the model ends the turn.
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("All done.")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "All done.",
        ),
      ])

      memory = H2code::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = H2code::Tools::Registry.new
      tools.register(H2code::Tools::CreateGoal.new)
      tools.register(H2code::Tools::GetGoal.new)
      tools.register(H2code::Tools::UpdateGoal.new)
      tools.register(H2code::Tools::SetGoalBudget.new)

      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of H2code::Loop::Event
      agent.run_goal_turn("Fix all failing tests", nil) { |e| events << e }

      # After completion, the goal record is cleared.
      (H2code::Tools::Goal.service || raise "Goal.service not initialized").get_goal.should be_nil

      # Three turns ran: initial + 2 continuations.
      turn_ends = events.count { |e| e.type.turn_end? }
      turn_ends.should eq(3)
    ensure
      H2code::Tools::Goal.service = nil
      FileUtils.rm_rf(work_dir) if work_dir
    end
  end

  it "blocks the goal when a turn budget is reached" do
    work_dir = File.join(Dir.tempdir, "h2code-goal-budget-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      service = H2code::Tools::AgentGoalService.new
      H2code::Tools::Goal.service = service

      # Step 1: CreateGoal + SetGoalBudget(turns=1).
      provider = H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [
            H2code::LLM::ToolCallPart.new(
              "gc_1", H2code::Tools::Names::CREATE_GOAL,
              %({"objective":"Small task"})
            ),
            H2code::LLM::ToolCallPart.new(
              "sb_1", H2code::Tools::Names::SET_GOAL_BUDGET, %({"value":1,"unit":"turns"})
            ),
          ] of H2code::LLM::MessagePart,
          stop_reason: "tool_use",
        ),
        # Step 2: continuation — model does work, doesn't call UpdateGoal.
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("Doing work...")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "Doing work...",
        ),
      ])

      memory = H2code::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = H2code::Tools::Registry.new
      tools.register(H2code::Tools::CreateGoal.new)
      tools.register(H2code::Tools::GetGoal.new)
      tools.register(H2code::Tools::UpdateGoal.new)
      tools.register(H2code::Tools::SetGoalBudget.new)

      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of H2code::Loop::Event
      agent.run_goal_turn("do it", nil) { |e| events << e }

      goal = service.get_goal
      goal.should_not be_nil
      if g = goal
        g.status.blocked?.should be_true
        (g.terminal_reason || "").should contain("budget")
      end
    ensure
      H2code::Tools::Goal.service = nil
      FileUtils.rm_rf(work_dir) if work_dir
    end
  end
end
