require "../spec_helper"
require "file_utils"

# Distinct helper name: spec/session/session_spec.cr already defines a
# top-level `temp_home`; both files compile into one spec binary.
def lock_temp_home : String
  File.join(Dir.tempdir, "hcode-test-#{Random::Secure.hex(8)}")
end

describe Hcode::Session::Lock do
  it "conflicts when another handle holds the lock (flock, even in-process)" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".hcode", "sessions", "aaa")
      Dir.mkdir_p(dir)
      lock = Hcode::Session::Lock.acquire!(dir)
      expect_raises(Hcode::Session::SessionBusyError) do
        Hcode::Session::Lock.acquire!(dir)
      end
      lock.release
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "reports the holder pid in the error" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".hcode", "sessions", "bbb")
      Dir.mkdir_p(dir)
      lock = Hcode::Session::Lock.acquire!(dir)
      begin
        Hcode::Session::Lock.acquire!(dir)
        fail "expected SessionBusyError"
      rescue ex : Hcode::Session::SessionBusyError
        ex.holder_pid.should eq(Process.pid)
        ex.message.to_s.should contain("pid #{Process.pid}")
      end
      lock.release
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "is re-acquirable after release" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".hcode", "sessions", "ccc")
      Dir.mkdir_p(dir)
      lock = Hcode::Session::Lock.acquire!(dir)
      lock.release
      lock.release # idempotent
      again = Hcode::Session::Lock.acquire!(dir)
      again.release
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

describe "Session store locking" do
  it "open_existing! rejects a session owned by another store" do
    home = lock_temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      owner = lc.create("/repo", "owner")
      expect_raises(Hcode::Session::SessionBusyError) do
        Hcode::Session::Store.open_existing!(owner.session_dir)
      end
      owner.unlock
      second = Hcode::Session::Store.open_existing!(owner.session_dir)
      second.unlock
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "open_existing! still raises FileDeletedError before locking" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".hcode", "sessions", "deleted10")
      expect_raises(Hcode::Session::FileDeletedError) do
        Hcode::Session::Store.open_existing!(dir)
      end
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "adopt releases the old session's lock and takes the target's" do
    home = lock_temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      first = lc.create("/repo", "first")
      dir1 = first.session_dir

      # TUI fork flow: fork the owned session, then adopt the fork — the
      # store must release dir1's lock and take the fork's.
      forked = lc.fork(first, "/repo")
      first.adopt(forked)

      # The adopted (fork) session is now owned by `first`.
      expect_raises(Hcode::Session::SessionBusyError) do
        Hcode::Session::Store.open_existing!(first.session_dir)
      end
      # dir1's lock was released by the adopt — openable again.
      reopened = Hcode::Session::Store.open_existing!(dir1)
      reopened.unlock
      first.unlock
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "plain Store.new stays lock-free (metadata ops on foreign sessions)" do
    home = lock_temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      owner = lc.create("/repo", "owned")
      # rename/archive build lock-free stores over sessions that may be
      # owned by other processes; only state.json is touched.
      meta = Hcode::Session::Store.new(owner.session_dir).read_state
      meta.should_not be_nil
      meta.try(&.title).should eq("owned")
      owner.unlock
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
