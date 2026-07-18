require "../spec_helper"
require "file_utils"

def temp_home : String
  File.join(Dir.tempdir, "hcode-test-#{Random::Secure.hex(8)}")
end

describe Hcode::Session::Index do
  it ".workspace_id is stable for the same path" do
    a = Hcode::Session::Index.workspace_id("/home/oleg/hcode-code")
    b = Hcode::Session::Index.workspace_id("/home/oleg/hcode-code")
    a.should eq(b)
    a.size.should eq(12)
  end

  it ".workspace_id differs for different paths" do
    a = Hcode::Session::Index.workspace_id("/home/oleg/hcode-code")
    b = Hcode::Session::Index.workspace_id("/home/oleg/other")
    a.should_not eq(b)
  end

  it "lists workspace-aware v2 sessions" do
    home = temp_home
    begin
      ws = Hcode::Session::Index.workspace_id("/repo")
      dir = File.join(home, ".hcode", "sessions", ws, "abc123def456")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"hello there"}}))
      meta = Hcode::Session::StateMeta.new("abc123def456")
      meta.cwd = "/repo"
      meta.title = "my session"
      meta.workspace_id = ws
      File.write(File.join(dir, "state.json"), meta.to_json)

      idx = Hcode::Session::Index.new(home)
      entries = idx.list
      entries.size.should eq(1)
      entries[0].id.should eq("abc123def456")
      entries[0].title.should eq("my session")
      entries[0].workspace_id.should eq(ws)
      entries[0].preview.should eq("hello there")
      entries[0].legacy?.should be_false
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "lists legacy flat-layout sessions" do
    home = temp_home
    begin
      dir = File.join(home, ".hcode", "sessions", "legacy001")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"old session"}}))
      File.write(File.join(dir, "meta.json"), %({"id":"legacy001","created_at":"2026-01-01T00:00:00Z"}))

      idx = Hcode::Session::Index.new(home)
      entries = idx.list
      entries.size.should eq(1)
      entries[0].id.should eq("legacy001")
      entries[0].preview.should eq("old session")
      entries[0].legacy?.should be_true
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "hides archived sessions by default" do
    home = temp_home
    begin
      ws = Hcode::Session::Index.workspace_id("/repo")
      active = File.join(home, ".hcode", "sessions", ws, "a1" * 6)
      archived = File.join(home, ".hcode", "sessions", ws, "b2" * 6)
      [active, archived].each { |d| Dir.mkdir_p(d) }
      [active, archived].each do |d|
        File.write(File.join(d, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"x"}}))
      end
      am = Hcode::Session::StateMeta.new("a1" * 6)
      File.write(File.join(active, "state.json"), am.to_json)
      bm = Hcode::Session::StateMeta.new("b2" * 6)
      bm.archived = true
      File.write(File.join(archived, "state.json"), bm.to_json)

      idx = Hcode::Session::Index.new(home)
      idx.list.size.should eq(1)
      idx.list(include_archived: true).size.should eq(2)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "finds a session by id across layouts" do
    home = temp_home
    begin
      ws = Hcode::Session::Index.workspace_id("/repo")
      dir = File.join(home, ".hcode", "sessions", ws, "deadbeefdead")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"x"}}))
      File.write(File.join(dir, "state.json"), Hcode::Session::StateMeta.new("deadbeefdead").to_json)

      idx = Hcode::Session::Index.new(home)
      idx.get("deadbeefdead").should_not be_nil
      idx.get("nonexistent").should be_nil
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

describe Hcode::Session::Lifecycle do
  it "creates a workspace-aware session with state.json" do
    home = temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      store = lc.create("/my/repo", "test title")

      File.exists?(File.join(store.session_dir, "state.json")).should be_true
      meta = store.read_state.not_nil!
      meta.id.should_not be_empty
      meta.cwd.should eq("/my/repo")
      meta.title.should eq("test title")
      meta.workspace_id.should eq(Hcode::Session::Index.workspace_id("/my/repo"))
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "fork copies the wire log into a new session" do
    home = temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      src = lc.create("/repo", "original")
      src.append("turn.prompt", {"prompt" => JSON::Any.new("hello")})

      forked = lc.fork(src, "/repo")
      forked.session_dir.should_not eq(src.session_dir)
      File.exists?(File.join(forked.session_dir, "wire.jsonl")).should be_true
      forked.read_state.not_nil!.title.should eq("Fork of original")

      # Replaying the fork reconstructs the original prompt.
      mem = Hcode::Context::Memory.new
      forked.replay(mem)
      mem.messages.first?.try(&.content).should eq("hello")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "archive hides a session, restore brings it back" do
    home = temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      store = lc.create("/repo")
      id = store.read_state.not_nil!.id

      lc.archive(id)
      lc.index.list.size.should eq(0)
      lc.index.list(include_archived: true).size.should eq(1)

      lc.restore(id)
      lc.index.list.size.should eq(1)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "rename updates the title" do
    home = temp_home
    begin
      lc = Hcode::Session::Lifecycle.new(home)
      store = lc.create("/repo", "old")
      id = store.read_state.not_nil!.id

      lc.rename(id, "new title")
      entry = lc.index.get(id).not_nil!
      entry.title.should eq("new title")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

describe Hcode::Session::Store do
  it ".new_workspace_session writes the v2 layout" do
    home = temp_home
    begin
      store = Hcode::Session::Store.new_workspace_session(home, "/repo", "ws")
      File.exists?(File.join(store.session_dir, "state.json")).should be_true
      meta = store.read_state.not_nil!
      meta.cwd.should eq("/repo")
      meta.workspace_id.should eq(Hcode::Session::Index.workspace_id("/repo"))
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "read_state falls back to legacy meta.json" do
    home = temp_home
    begin
      dir = File.join(home, ".hcode", "sessions", "legacy01")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "meta.json"), %({"id":"legacy01","created_at":"2026-01-01T00:00:00Z"}))
      store = Hcode::Session::Store.new(dir)
      meta = store.read_state.not_nil!
      meta.id.should eq("legacy01")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
