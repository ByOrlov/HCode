require "../spec_helper"

describe H2code::Notify::StatusTracker do
  it "starts idle" do
    tracker = H2code::Notify::StatusTracker.new { |_| }
    tracker.status.should eq(H2code::Notify::AgentStatus::Idle)
  end

  it "fires a transition only on real change" do
    transitions = [] of H2code::Notify::Transition
    tracker = H2code::Notify::StatusTracker.new { |t| transitions << t }

    tracker.transition!(H2code::Notify::AgentStatus::Working)
    tracker.transition!(H2code::Notify::AgentStatus::Working) # no-op
    tracker.transition!(H2code::Notify::AgentStatus::Done, "Turn complete")
    tracker.transition!(H2code::Notify::AgentStatus::Done) # no-op

    transitions.map(&.event).should eq(["turn_started", "turn_done"])
    transitions[1].title.should eq("Turn complete")
    transitions[1].prev_status.should eq(H2code::Notify::AgentStatus::Working)
    transitions[1].next_status.should eq(H2code::Notify::AgentStatus::Done)
  end

  it "maps edges to stable event names" do
    transitions = [] of H2code::Notify::Transition
    tracker = H2code::Notify::StatusTracker.new { |t| transitions << t }

    tracker.transition!(H2code::Notify::AgentStatus::Working)
    tracker.transition!(H2code::Notify::AgentStatus::InputRequired)
    tracker.transition!(H2code::Notify::AgentStatus::Working)
    tracker.transition!(H2code::Notify::AgentStatus::Done)
    tracker.transition!(H2code::Notify::AgentStatus::Idle)

    transitions.map(&.event).should eq(["turn_started", "input_required", "resumed", "turn_done", "settled"])
  end
end
