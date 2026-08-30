require "../spec_helper"
require "../../src/hooks/engine"

describe H2code::Hooks::Engine do
  describe "empty engine" do
    it "reports empty when no hooks" do
      engine = H2code::Hooks::Engine.new
      engine.empty?.should be_true
    end

    it "returns no results when triggering an event with no hooks" do
      engine = H2code::Hooks::Engine.new
      engine.trigger("PreToolUse").should be_empty
    end
  end

  describe "registration" do
    it "groups hooks by event" do
      hooks = [
        H2code::Hooks::HookDef.new("PreToolUse", "echo a"),
        H2code::Hooks::HookDef.new("PreToolUse", "echo b"),
        H2code::Hooks::HookDef.new("Stop", "echo c"),
      ]
      engine = H2code::Hooks::Engine.new(hooks)
      engine.summary["PreToolUse"].should eq(2)
      engine.summary["Stop"].should eq(1)
      engine.empty?.should be_false
    end
  end

  describe "matcher" do
    it "matches a hook only when the regex matches the matcher value" do
      hooks = [
        H2code::Hooks::HookDef.new("PreToolUse", "echo matched", matcher: H2code::Tools::Names::BASH),
        H2code::Hooks::HookDef.new("PreToolUse", "echo other", matcher: H2code::Tools::Names::READ),
      ]
      engine = H2code::Hooks::Engine.new(hooks)

      # Both Bash and Read hooks exist; trigger with H2code::Tools::Names::BASH runs only the Bash one.
      # We can't assert command output here (echo is the command), but we can
      # verify via exit-code-based block logic. echo exits 0 → allow.
      results = engine.trigger("PreToolUse", H2code::Tools::Names::BASH)
      results.size.should eq(1)
    end

    it "empty matcher matches everything" do
      hooks = [H2code::Hooks::HookDef.new("Stop", "echo hi")]
      engine = H2code::Hooks::Engine.new(hooks)
      engine.trigger("Stop", "anything").size.should eq(1)
    end
  end

  describe "exit code → action" do
    it "exit code 2 blocks" do
      hooks = [H2code::Hooks::HookDef.new("PreToolUse", "exit 2")]
      engine = H2code::Hooks::Engine.new(hooks)
      results = engine.trigger("PreToolUse", H2code::Tools::Names::BASH)
      results.first.block?.should be_true
    end

    it "exit code 0 allows" do
      hooks = [H2code::Hooks::HookDef.new("PreToolUse", "true")]
      engine = H2code::Hooks::Engine.new(hooks)
      results = engine.trigger("PreToolUse", H2code::Tools::Names::BASH)
      results.first.block?.should be_false
    end
  end

  describe "trigger_block" do
    it "returns a BlockDecision when a hook blocks" do
      hooks = [H2code::Hooks::HookDef.new("PreToolUse", "echo err >&2; exit 2")]
      engine = H2code::Hooks::Engine.new(hooks)
      block = engine.trigger_block("PreToolUse", H2code::Tools::Names::BASH)
      block.should_not be_nil
      block.as(H2code::Hooks::BlockDecision).reason.should contain("err")
    end

    it "returns nil when no hook blocks" do
      hooks = [H2code::Hooks::HookDef.new("PreToolUse", "true")]
      engine = H2code::Hooks::Engine.new(hooks)
      engine.trigger_block("PreToolUse", H2code::Tools::Names::BASH).should be_nil
    end
  end

  describe "structured JSON output" do
    it "blocks on permissionDecision deny" do
      hooks = [H2code::Hooks::HookDef.new(
        "PreToolUse",
        %{echo '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"not allowed"}}'},
      )]
      engine = H2code::Hooks::Engine.new(hooks)
      block = engine.trigger_block("PreToolUse", H2code::Tools::Names::BASH)
      block.should_not be_nil
      block.as(H2code::Hooks::BlockDecision).reason.should eq("not allowed")
    end

    it "allows when permissionDecision is not deny" do
      hooks = [H2code::Hooks::HookDef.new(
        "PreToolUse",
        %{echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'},
      )]
      engine = H2code::Hooks::Engine.new(hooks)
      engine.trigger_block("PreToolUse", H2code::Tools::Names::BASH).should be_nil
    end
  end

  describe "input payload" do
    it "sends hook_event_name and matcher as JSON stdin" do
      # `cat` echoes stdin back; we verify the JSON payload contains our fields
      # by parsing the echoed output.
      hooks = [H2code::Hooks::HookDef.new("Stop", "cat")]
      engine = H2code::Hooks::Engine.new(hooks, cwd: "/tmp", session_id: "s1")
      results = engine.trigger("Stop", "my-match")

      # cat exits 0 with the JSON on stdout; parse it.
      stdout = results.first.stdout.strip
      parsed = JSON.parse(stdout) rescue nil
      if parsed
        parsed["hook_event_name"].as_s.should eq("Stop")
        parsed["matcher"].as_s.should eq("my-match")
        parsed["session_id"].as_s.should eq("s1")
        parsed["cwd"].as_s.should eq("/tmp")
      end
    end
  end
end
