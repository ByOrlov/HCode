require "../spec_helper"

describe Hcode::Notify::Player do
  describe ".candidates_for" do
    it "lists afplay first on macOS" do
      cands = Hcode::Notify::Player.candidates_for("macos")
      cands[0][0].should eq("afplay")
      cands.last[0].should eq("ffplay")
    end

    it "lists pw-play first on Linux" do
      cands = Hcode::Notify::Player.candidates_for("unix")
      cands[0][0].should eq("pw-play")
      cands.map(&.[0]).should contain("aplay")
      cands.last[0].should eq("ffplay")
    end

    it "lists powershell first on Windows" do
      cands = Hcode::Notify::Player.candidates_for("windows")
      cands[0][0].should eq("powershell")
      cands.last[0].should eq("ffplay")
    end
  end

  describe "#play_for" do
    it "does not crash when no player is available" do
      player = Hcode::Notify::Player.new(probe: false)
      player.play_for("turn_done") # no crash, no sound
    end

    it "does not crash when the sound file is missing" do
      player = Hcode::Notify::Player.new(
        done_path: "/nonexistent/done.mp3",
        alert_path: "/nonexistent/alert.mp3",
        probe: false,
      )
      player.play_for("turn_done")
      player.play_for("input_required")
    end
  end

  describe ".resolve_player" do
    it "returns a player or nil" do
      result = Hcode::Notify::Player.resolve_player("macos")
      # Either a resolved command tuple or nil — both are acceptable here.
      (result.nil? || result.is_a?(Tuple)).should be_true
    end
  end
end
