require "../spec_helper"

describe Hcode::Notify::StatusTracker do
  it "starts idle" do
    tracker = Hcode::Notify::StatusTracker.new { |_| }
    tracker.status.should eq(Hcode::Notify::AgentStatus::Idle)
  end

  it "fires a transition only on real change" do
    transitions = [] of Hcode::Notify::Transition
    tracker = Hcode::Notify::StatusTracker.new { |t| transitions << t }

    tracker.transition!(Hcode::Notify::AgentStatus::Working)
    tracker.transition!(Hcode::Notify::AgentStatus::Working) # no-op
    tracker.transition!(Hcode::Notify::AgentStatus::Done, "Turn complete")
    tracker.transition!(Hcode::Notify::AgentStatus::Done) # no-op

    transitions.map(&.event).should eq(["turn_started", "turn_done"])
    transitions[1].title.should eq("Turn complete")
    transitions[1].prev_status.should eq(Hcode::Notify::AgentStatus::Working)
    transitions[1].next_status.should eq(Hcode::Notify::AgentStatus::Done)
  end

  it "maps edges to stable event names" do
    transitions = [] of Hcode::Notify::Transition
    tracker = Hcode::Notify::StatusTracker.new { |t| transitions << t }

    tracker.transition!(Hcode::Notify::AgentStatus::Working)
    tracker.transition!(Hcode::Notify::AgentStatus::InputRequired)
    tracker.transition!(Hcode::Notify::AgentStatus::Working)
    tracker.transition!(Hcode::Notify::AgentStatus::Done)
    tracker.transition!(Hcode::Notify::AgentStatus::Idle)

    transitions.map(&.event).should eq(["turn_started", "input_required", "resumed", "turn_done", "settled"])
  end
end
