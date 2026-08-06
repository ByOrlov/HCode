require "../spec_helper"
require "../../src/tools/goal"

describe Hcode::Tools::CreateGoal do
  before_each do
    Hcode::Tools::Goal.service = Hcode::Tools::AgentGoalService.new
  end
  after_each do
    Hcode::Tools::Goal.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::CreateGoal.new
    tool.name.should eq("CreateGoal")
    tool.description.should contain("durable")
    props = tool.parameters["properties"].as_h
    props.has_key?("objective").should be_true
    props.has_key?("completionCriterion").should be_true
    props.has_key?("replace").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["objective"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "creates a goal and returns pretty JSON" do
    tool = Hcode::Tools::CreateGoal.new
    result = tool.execute(JSON.parse(%({
      "objective": "Ship the release",
      "completionCriterion": "Tagged v1.0"
    })))
    result.is_error?.should be_false
    result.content.should contain(%("goal":))
    result.content.should contain(%("objective": "Ship the release"))
    result.content.should contain(%("completionCriterion": "Tagged v1.0"))
    result.content.should contain(%("status": "active"))
    result.content.should contain(%("turnsUsed": 0))
  end

  it "omits goal_id from model-facing JSON" do
    tool = Hcode::Tools::CreateGoal.new
    result = tool.execute(JSON.parse(%({ "objective": "x" })))
    result.content.should_not contain("goal_id")
    result.content.should_not contain("goalId")
  end

  it "fails on empty objective" do
    tool = Hcode::Tools::CreateGoal.new
    result = tool.execute(JSON.parse(%({ "objective": "   " })))
    result.is_error?.should be_true
    result.content.should contain("must not be empty")
  end

  it "fails on too-long objective" do
    tool = Hcode::Tools::CreateGoal.new
    long = "x" * (Hcode::Tools::Goal::MAX_OBJECTIVE_LENGTH + 1)
    result = tool.execute(JSON.parse(%({ "objective": "#{long}" })))
    result.is_error?.should be_true
    result.content.should contain("maximum length")
  end

  it "fails when a goal already exists without replace" do
    tool = Hcode::Tools::CreateGoal.new
    tool.execute(JSON.parse(%({ "objective": "first" })))
    result = tool.execute(JSON.parse(%({ "objective": "second" })))
    result.is_error?.should be_true
    result.content.should contain("already exists")
  end

  it "replaces the existing goal when replace=true" do
    tool = Hcode::Tools::CreateGoal.new
    first = tool.execute(JSON.parse(%({ "objective": "first" })))
    second = tool.execute(JSON.parse(%({ "objective": "second", "replace": true })))
    second.is_error?.should be_false
    second.content.should contain(%("objective": "second"))
  end

  it "fails when no service is registered" do
    Hcode::Tools::Goal.service = nil
    tool = Hcode::Tools::CreateGoal.new
    result = tool.execute(JSON.parse(%({ "objective": "x" })))
    result.is_error?.should be_true
    result.content.should contain("not initialized")
  end
end

describe Hcode::Tools::GetGoal do
  after_each { Hcode::Tools::Goal.service = nil }

  it "returns null when no current goal" do
    Hcode::Tools::Goal.service = Hcode::Tools::AgentGoalService.new
    tool = Hcode::Tools::GetGoal.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain(%("goal": null))
  end

  it "returns snapshot when goal exists" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::GetGoal.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain(%("objective": "ship"))
    result.content.should contain(%("status": "active"))
  end
end

describe Hcode::Tools::UpdateGoal do
  before_each do
    Hcode::Tools::Goal.service = Hcode::Tools::AgentGoalService.new
  end
  after_each { Hcode::Tools::Goal.service = nil }

  it "rejects invalid status" do
    tool = Hcode::Tools::UpdateGoal.new
    result = tool.execute(JSON.parse(%({ "status": "paused" })))
    result.is_error?.should be_true
    result.content.should contain("Invalid goal status")
  end

  it "returns missing-goal message when no goal and status=active" do
    tool = Hcode::Tools::UpdateGoal.new
    result = tool.execute(JSON.parse(%({ "status": "active" })))
    result.is_error?.should be_false
    result.content.should contain("not resumed: no current goal")
  end

  it "marks goal complete and renders completion prompt" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::UpdateGoal.new
    result = tool.execute(JSON.parse(%({ "status": "complete" })))
    result.is_error?.should be_false
    result.content.should contain("Goal completed successfully")
    result.content.should contain("0 turns")
    result.content.should contain("0 tokens")
  end

  it "marks goal blocked and renders blocked prompt" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::UpdateGoal.new
    result = tool.execute(JSON.parse(%({ "status": "blocked" })))
    result.is_error?.should be_false
    result.content.should contain("Goal blocked")
    result.content.should contain("input or change")
  end

  it "formats elapsed time correctly" do
    tool = Hcode::Tools::UpdateGoal.new
    tool.format_elapsed(45_000).should eq("45s")
    tool.format_elapsed(303_000).should eq("5m03s")
    tool.format_elapsed(3_661_000).should eq("1h01m")
  end

  it "formats token counts correctly" do
    tool = Hcode::Tools::UpdateGoal.new
    tool.format_tokens(500).should eq("500")
    tool.format_tokens(2500).should eq("2.5k")
    tool.format_tokens(2_500_000).should eq("2.5M")
  end
end

describe Hcode::Tools::SetGoalBudget do
  before_each do
    Hcode::Tools::Goal.service = Hcode::Tools::AgentGoalService.new
  end
  after_each { Hcode::Tools::Goal.service = nil }

  it "sets turn budget" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::SetGoalBudget.new
    result = tool.execute(JSON.parse(%({ "value": 20, "unit": "turns" })))
    result.is_error?.should be_false
    result.content.should contain("Goal budget set: 20 turns")
  end

  it "sets token budget" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::SetGoalBudget.new
    result = tool.execute(JSON.parse(%({ "value": 500000, "unit": "tokens" })))
    result.is_error?.should be_false
    result.content.should contain("500000 tokens")
  end

  it "sets time budget (minutes)" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::SetGoalBudget.new
    result = tool.execute(JSON.parse(%({ "value": 30, "unit": "minutes" })))
    result.is_error?.should be_false
    result.content.should contain("30 minutes")
  end

  it "rejects unreasonable time budget" do
    service = Hcode::Tools::AgentGoalService.new
    Hcode::Tools::Goal.service = service
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

    tool = Hcode::Tools::SetGoalBudget.new
    # 100ms — слишком короткий.
    result = tool.execute(JSON.parse(%({ "value": 100, "unit": "milliseconds" })))
    result.is_error?.should be_false
    result.content.should contain("not a reasonable goal budget")
  end

  it "returns missing-goal when no current goal" do
    tool = Hcode::Tools::SetGoalBudget.new
    result = tool.execute(JSON.parse(%({ "value": 10, "unit": "turns" })))
    result.is_error?.should be_false
    result.content.should contain("no current goal")
  end

  it "rejects invalid unit" do
    tool = Hcode::Tools::SetGoalBudget.new
    result = tool.execute(JSON.parse(%({ "value": 10, "unit": "weeks" })))
    result.is_error?.should be_true
    result.content.should contain("Unsupported unit")
  end

  it "rejects non-positive value" do
    tool = Hcode::Tools::SetGoalBudget.new
    result = tool.execute(JSON.parse(%({ "value": 0, "unit": "turns" })))
    result.is_error?.should be_true
    result.content.should contain("positive number")
  end

  it "formats budget with correct singular/plural" do
    tool = Hcode::Tools::SetGoalBudget.new
    tool.format_budget(1.0, "turn").should eq("1 turn")
    tool.format_budget(2.0, "turns").should eq("2 turns")
    tool.format_budget(1.0, "token").should eq("1 token")
    tool.format_budget(1.0, "millisecond").should eq("1 millisecond")
    tool.format_budget(1.0, "seconds").should eq("1 second")
    tool.format_budget(2.0, "minutes").should eq("2 minutes")
    tool.format_budget(1.0, "hours").should eq("1 hour")
  end

  it "converts compound time units correctly" do
    tool = Hcode::Tools::SetGoalBudget.new
    tool.to_milliseconds(1.0, "milliseconds").should eq(1.0)
    tool.to_milliseconds(2.0, "seconds").should eq(2000.0)
    tool.to_milliseconds(3.0, "minutes").should eq(180_000.0)
    tool.to_milliseconds(1.0, "hours").should eq(3_600_000.0)
  end
end

describe Hcode::Tools::AgentGoalService do
  it "creates, pauses, resumes, and cancels a goal" do
    service = Hcode::Tools::AgentGoalService.new

    created = service.create_goal(Hcode::Tools::CreateGoalInput.new(
      objective: "Fix the bug",
      completion_criterion: "tests pass",
    ))
    created.status.active?.should be_true

    paused = service.pause_goal
    paused.status.paused?.should be_true

    resumed = service.resume_goal
    resumed.status.active?.should be_true

    cancelled = service.cancel_goal
    cancelled.status.complete?.should be_true
    cancelled.terminal_reason.should eq("cancelled")
  end

  it "returns nil snapshot when no goal exists" do
    service = Hcode::Tools::AgentGoalService.new
    service.get_goal.should be_nil
  end

  it "raises when pausing with no active goal" do
    service = Hcode::Tools::AgentGoalService.new
    expect_raises(Hcode::Tools::GoalError) do
      service.pause_goal
    end
  end

  it "replaces existing goal when replace=true" do
    service = Hcode::Tools::AgentGoalService.new
    service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "first"))
    replaced = service.create_goal(Hcode::Tools::CreateGoalInput.new(
      objective: "second",
      replace: true,
    ))
    replaced.objective.should eq("second")
  end

  describe "budget persistence and accounting" do
    it "set_budget_limits persists limits into the snapshot" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")

      service.set_budget_limits(
        Hcode::Tools::BudgetInput.new(
          Hcode::Tools::GoalBudgetLimits.new(turn_budget: 5, token_budget: 1000)
        )
      )
      goal = service.get_goal || raise "goal should not be nil"
      goal.budget_limits.turn_budget.should eq(5)
      goal.budget_limits.token_budget.should eq(1000)
      goal.budget.turn_budget.should eq(5)
      goal.budget.token_budget.should eq(1000)
    end

    it "marks over_budget when usage exceeds limits" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      service.set_budget_limits(
        Hcode::Tools::BudgetInput.new(
          Hcode::Tools::GoalBudgetLimits.new(turn_budget: 2)
        )
      )

      service.increment_turn
      service.increment_turn
      goal = service.get_goal || raise "goal should not be nil"
      goal.budget.over_budget?.should be_true
      goal.budget.turn_budget_reached?.should be_true
    end

    it "increment_turn is a no-op outside active" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      service.pause_goal
      result = service.increment_turn
      result.should be_nil
      (service.get_goal || raise "goal should not be nil").turns_used.should eq(0)
    end

    it "record_token_usage accumulates and clamps negative deltas" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      service.record_token_usage(100)
      service.record_token_usage(-50) # clamps to 0
      (service.get_goal || raise "goal should not be nil").tokens_used.should eq(100)
    end

    it "mark_complete clears the record" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      completed = service.mark_complete
      completed.should_not be_nil
      (completed || raise "completed should not be nil").status.complete?.should be_true
      service.get_goal.should be_nil
    end

    it "mark_blocked keeps the record (resumable)" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      blocked = service.mark_blocked
      blocked.should_not be_nil
      (blocked || raise "blocked should not be nil").status.blocked?.should be_true
      service.get_goal.should_not be_nil
    end

    it "pause_on_interrupt pauses an active goal" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      paused = service.pause_on_interrupt("Paused after interruption")
      paused.should_not be_nil
      if paused
        paused.status.paused?.should be_true
        paused.terminal_reason.should eq("Paused after interruption")
      end
    end

    it "pause_on_interrupt is a no-op for a non-active goal" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      service.pause_goal
      service.pause_on_interrupt.should be_nil
    end

    it "wall-clock accumulates across pause/resume intervals" do
      service = Hcode::Tools::AgentGoalService.new
      service.create_goal(Hcode::Tools::CreateGoalInput.new(objective: "ship"), "model")
      before = (service.get_goal || raise "goal should not be nil").live_wall_clock_ms
      service.pause_goal
      service.resume_goal
      after = (service.get_goal || raise "goal should not be nil").live_wall_clock_ms
      # After a pause+resume cycle, the accumulated wall_clock_ms should be
      # at least as large as before (the pause interval was folded in).
      after.should be >= before
    end
  end
end
