require "../spec_helper"
require "file_utils"

# Distinct helper name: other specs in this directory already define
# `temp_home` / `lock_temp_home`; all files compile into one spec binary.
def cleanup_temp_home : String
  File.join(Dir.tempdir, "h2code-cleanup-test-#{Random::Secure.hex(8)}")
end

describe H2code::Session::Cleanup do
  it "maps period names to day counts" do
    H2code::Session::Cleanup.period_days("week").should eq(7)
    H2code::Session::Cleanup.period_days("month").should eq(30)
    H2code::Session::Cleanup.period_days("6months").should eq(182)
    H2code::Session::Cleanup.period_days("year").should eq(365)
    H2code::Session::Cleanup.period_days("hour").should be_nil
  end

  it "deletes sessions and voice files older than the period, keeps the rest" do
    home = cleanup_temp_home
    begin
      sessions = File.join(home, ".h2code", "sessions")
      old_dir = File.join(sessions, "aaaaaaaaaaaa", "oldsess")
      new_dir = File.join(sessions, "aaaaaaaaaaaa", "newsess")
      [old_dir, new_dir].each { |d| FileUtils.mkdir_p(d) }
      old_wire = File.join(old_dir, "wire.jsonl")
      new_wire = File.join(new_dir, "wire.jsonl")
      File.write(old_wire, "")
      File.write(new_wire, "")

      old_time = Time.utc - 40.days # older than a month
      File.utime(old_time, old_time, old_wire)

      voice = File.join(home, ".h2code", "voice")
      FileUtils.mkdir_p(voice)
      old_clip = File.join(voice, "old.webm")
      new_clip = File.join(voice, "new.webm")
      File.write(old_clip, "x")
      File.write(new_clip, "x")
      File.utime(old_time, old_time, old_clip)

      result = H2code::Session::Cleanup.new(home).run("month")

      result.sessions_removed.should eq(1)
      result.voice_files_removed.should eq(1)
      Dir.exists?(old_dir).should be_false
      File.exists?(old_clip).should be_false
      # Recent data is untouched.
      File.exists?(new_wire).should be_true
      File.exists?(new_clip).should be_true
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "counts per-period sessions and voice files for the picker preview" do
    home = cleanup_temp_home
    begin
      sessions = File.join(home, ".h2code", "sessions")
      # Two sessions: ~10 days old (older than a week only) and ~400 days
      # old (older than every period).
      {"sess_week" => 10, "sess_old" => 400}.each do |name, age|
        dir = File.join(sessions, "aaaaaaaaaaaa", name)
        FileUtils.mkdir_p(dir)
        wire = File.join(dir, "wire.jsonl")
        File.write(wire, "")
        t = Time.utc - age.days
        File.utime(t, t, wire)
      end

      voice = File.join(home, ".h2code", "voice")
      FileUtils.mkdir_p(voice)
      {"v_week" => 10, "v_old" => 400, "v_fresh" => 1}.each do |name, age|
        clip = File.join(voice, "#{name}.webm")
        File.write(clip, "x")
        t = Time.utc - age.days
        File.utime(t, t, clip)
      end

      counts = H2code::Session::Cleanup.new(home).counts

      counts["week"].sessions.should eq(2) # both older than a week
      counts["week"].voice_files.should eq(2)
      counts["month"].sessions.should eq(1) # only the 400-day one
      counts["month"].voice_files.should eq(1)
      counts["year"].sessions.should eq(1)
      counts["year"].voice_files.should eq(1)

      # The excluded (current) session drops out of every bucket.
      excluded = H2code::Session::Cleanup.new(home).counts(skip_session_ids: ["sess_old"])
      excluded["year"].sessions.should eq(0)
      excluded["week"].sessions.should eq(1)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "never deletes the current session, however old" do
    home = cleanup_temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "aaaaaaaaaaaa", "current")
      FileUtils.mkdir_p(dir)
      wire = File.join(dir, "wire.jsonl")
      File.write(wire, "")
      old_time = Time.utc - 400.days
      File.utime(old_time, old_time, wire)

      result = H2code::Session::Cleanup.new(home).run("year", skip_session_ids: ["current"])

      result.sessions_removed.should eq(0)
      Dir.exists?(dir).should be_true
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "skips sessions locked by another process" do
    home = cleanup_temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "aaaaaaaaaaaa", "busy")
      FileUtils.mkdir_p(dir)
      wire = File.join(dir, "wire.jsonl")
      File.write(wire, "")
      old_time = Time.utc - 40.days
      File.utime(old_time, old_time, wire)

      lock = H2code::Session::Lock.acquire!(dir)
      begin
        result = H2code::Session::Cleanup.new(home).run("month")
        result.sessions_removed.should eq(0)
        result.sessions_skipped.should eq(1)
        Dir.exists?(dir).should be_true
      ensure
        lock.release
      end
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
