require "../spec_helper"
require "../../src/loop/dedup"

describe H2code::Loop::DedupTracker do
  it "allows the first call" do
    tracker = H2code::Loop::DedupTracker.new
    tracker.check_and_track(H2code::Tools::Names::EDIT, %({"path":"a.txt"})).should eq(H2code::Loop::DedupTracker::DedupAction::Allow)
  end

  it "escalates through reminder → menu → warning → force-stop on identical args" do
    tracker = H2code::Loop::DedupTracker.new
    args = %({"path":"a.txt","old_string":"x","new_string":"y"})

    # streak 1, 2 → Allow
    2.times { tracker.check_and_track(H2code::Tools::Names::EDIT, args).should eq(H2code::Loop::DedupTracker::DedupAction::Allow) }
    # streak 3 → Reminder
    tracker.check_and_track(H2code::Tools::Names::EDIT, args).should eq(H2code::Loop::DedupTracker::DedupAction::Reminder)
    # streak 4 → Reminder (still < 5)
    tracker.check_and_track(H2code::Tools::Names::EDIT, args).should eq(H2code::Loop::DedupTracker::DedupAction::Reminder)
    # streak 5 → DecisionMenu
    tracker.check_and_track(H2code::Tools::Names::EDIT, args).should eq(H2code::Loop::DedupTracker::DedupAction::DecisionMenu)
    # streak 6, 7 → DecisionMenu (still < 8)
    2.times { tracker.check_and_track(H2code::Tools::Names::EDIT, args) }
    # streak 8 → FinalWarning
    tracker.check_and_track(H2code::Tools::Names::EDIT, args).should eq(H2code::Loop::DedupTracker::DedupAction::FinalWarning)
    # streak 9, 10, 11 → FinalWarning (still < 12)
    3.times { tracker.check_and_track(H2code::Tools::Names::EDIT, args) }
    # streak 12 → ForceStop
    tracker.check_and_track(H2code::Tools::Names::EDIT, args).should eq(H2code::Loop::DedupTracker::DedupAction::ForceStop)
  end

  it "resets the streak when args change" do
    tracker = H2code::Loop::DedupTracker.new
    args1 = %({"path":"a.txt","old_string":"x","new_string":"y"})
    args2 = %({"path":"b.txt","old_string":"x","new_string":"z"})

    4.times { tracker.check_and_track(H2code::Tools::Names::EDIT, args1) }
    tracker.check_and_track(H2code::Tools::Names::EDIT, args2).should eq(H2code::Loop::DedupTracker::DedupAction::Allow)
  end

  it "tracks tools independently" do
    tracker = H2code::Loop::DedupTracker.new
    args = %({"path":"a.txt"})

    4.times { tracker.check_and_track(H2code::Tools::Names::EDIT, args) }
    tracker.check_and_track(H2code::Tools::Names::READ, args).should eq(H2code::Loop::DedupTracker::DedupAction::Allow)
  end

  # Fix 1 regression: SHA256 + ring buffer. Verifies the tracker never
  # retains the canonical args string — see plans/TOOLS-LEAKS.md §A1.
  describe "memory-bounded retention (Fix 1)" do
    it "caps per-tool history at MAX_HISTORY entries" do
      tracker = H2code::Loop::DedupTracker.new
      cap = H2code::Loop::DedupTracker::MAX_HISTORY

      (cap + 50).times do |i|
        tracker.check_and_track(H2code::Tools::Names::EDIT, %({"path":"f#{i}.txt","old_string":"x","new_string":"y#{i}"}))
      end

      history = tracker.@call_history[H2code::Tools::Names::EDIT]?
      history.should_not be_nil
      (history || raise "history should not be nil").size.should eq(cap)
    end

    it "treats the same canonical args as the same call regardless of size" do
      tracker = H2code::Loop::DedupTracker.new
      small = %({"path":"a.txt","old_string":"x","new_string":"y"})
      large = small + ("q" * 200_000) # very different bytes, but same JSON prefix

      2.times { tracker.check_and_track(H2code::Tools::Names::EDIT, small) }
      # Different args → streak resets
      tracker.check_and_track(H2code::Tools::Names::EDIT, large).should eq(H2code::Loop::DedupTracker::DedupAction::Allow)
    end

    it "still detects repetition across the ring boundary" do
      tracker = H2code::Loop::DedupTracker.new
      cap = H2code::Loop::DedupTracker::MAX_HISTORY

      # Fill the ring with distinct calls so the first one is evicted.
      cap.times do |i|
        tracker.check_and_track(H2code::Tools::Names::EDIT, %({"path":"f#{i}.txt"}))
      end
      # Now the very first args should not be in the ring → streak resets to 1.
      tracker.check_and_track(H2code::Tools::Names::EDIT, %({"path":"f0.txt"})).should eq(H2code::Loop::DedupTracker::DedupAction::Allow)
    end

    it "does not retain the full args payload (hash-only storage)" do
      tracker = H2code::Loop::DedupTracker.new
      payload = "x" * 500_000 # 500 KB body
      args = %({"path":"a.txt","old_string":"#{payload}","new_string":"y"})

      tracker.check_and_track(H2code::Tools::Names::EDIT, args)
      tracker.check_and_track(H2code::Tools::Names::EDIT, args)

      # The internal storage should not contain the payload string itself;
      # only 64-char SHA256 hex digests.
      history = tracker.@call_history[H2code::Tools::Names::EDIT]
      history.each do |entry|
        entry.size.should eq(64)            # SHA256 hex digest length
        entry.should_not contain("x" * 100) # no payload leak
      end
    end
  end
end
