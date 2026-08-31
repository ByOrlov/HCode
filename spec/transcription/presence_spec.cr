require "../spec_helper"
require "../../src/transcription/presence"

# Pin HOME and PATH to temp dirs so the adapter probes a controlled
# filesystem instead of the developer's machine.
def with_voice_env(home : String, path : String, &)
  old_home = ENV["HOME"]?
  old_path = ENV["PATH"]?
  ENV["HOME"] = home
  ENV["PATH"] = path
  begin
    yield
  ensure
    ENV["HOME"] = old_home
    ENV["PATH"] = old_path
  end
end

{% unless flag?(:win32) %}
  describe H2code::Transcription::VoicePresencePort do
    it "detects an h2voice executable on PATH" do
      bin = File.join(Dir.tempdir, "presence-bin-#{Random::Secure.hex(6)}")
      home = File.join(Dir.tempdir, "presence-home-#{Random::Secure.hex(6)}")
      Dir.mkdir(bin)
      Dir.mkdir(home)
      exe = File.join(bin, "h2voice")
      File.write(exe, "#!/bin/sh\n")
      File.chmod(exe, 0o755)
      begin
        with_voice_env(home, bin) do
          H2code::Transcription::UnixVoicePresence.new.installed?.should be_true
        end
      ensure
        File.delete(exe) rescue nil
        Dir.delete(bin) rescue nil
        Dir.delete(home) rescue nil
      end
    end

    it "detects the ~/.h2voice data directory" do
      home = File.join(Dir.tempdir, "presence-home-#{Random::Secure.hex(6)}")
      empty = File.join(Dir.tempdir, "presence-empty-#{Random::Secure.hex(6)}")
      Dir.mkdir(home)
      Dir.mkdir(empty)
      Dir.mkdir(File.join(home, ".h2voice"))
      begin
        with_voice_env(home, empty) do
          H2code::Transcription::UnixVoicePresence.new.installed?.should be_true
        end
      ensure
        Dir.delete(File.join(home, ".h2voice")) rescue nil
        Dir.delete(home) rescue nil
        Dir.delete(empty) rescue nil
      end
    end

    it "reports not installed with no binary and no ~/.h2voice" do
      home = File.join(Dir.tempdir, "presence-home-#{Random::Secure.hex(6)}")
      empty = File.join(Dir.tempdir, "presence-empty-#{Random::Secure.hex(6)}")
      Dir.mkdir(home)
      Dir.mkdir(empty)
      begin
        with_voice_env(home, empty) do
          H2code::Transcription::UnixVoicePresence.new.installed?.should be_false
        end
      ensure
        Dir.delete(home) rescue nil
        Dir.delete(empty) rescue nil
      end
    end

    it "exposes the install URL for the TUI advice" do
      H2code::Transcription::VoicePresencePort::INSTALL_URL.should start_with("https://")
    end

    it "selects the Unix adapter on this platform" do
      H2code::Transcription::VoicePresencePort.default.should be_a(H2code::Transcription::UnixVoicePresence)
    end
  end
{% end %}
