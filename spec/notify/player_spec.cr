require "../spec_helper"

describe H2code::Notify::Player do
  describe ".new" do
    it "defaults to enabled with volume 70" do
      player = H2code::Notify::Player.new
      player.enabled?.should be_true
      player.volume.should eq(70)
    end

    it "accepts custom volume and enabled flag" do
      player = H2code::Notify::Player.new(volume: 42, enabled: false)
      player.volume.should eq(42)
      player.enabled?.should be_false
    end
  end

  describe "DEFAULT_SOUND" do
    it "contains embedded OGG data (non-empty)" do
      H2code::Notify::Player::DEFAULT_SOUND.bytesize.should be > 0
    end

    it "starts with the Ogg Vorbis magic bytes (OggS)" do
      H2code::Notify::Player::DEFAULT_SOUND[0, 4].should eq("OggS")
    end
  end

  describe "#play_for" do
    it "does not crash when disabled" do
      player = H2code::Notify::Player.new(enabled: false)
      player.play_for("turn_done") # no crash, no sound
    end

    it "does not crash for unknown events" do
      player = H2code::Notify::Player.new(enabled: false)
      player.play_for("unknown_event")
    end
  end

  describe "#volume=" do
    it "updates the volume" do
      player = H2code::Notify::Player.new
      player.volume = 50
      player.volume.should eq(50)
    end
  end
end
