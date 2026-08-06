require "../spec_helper"

describe Hcode::Plugin::Manager do
  it "loads with no plugins" do
    with_tmpdir do |home|
      mgr = Hcode::Plugin::Manager.new(home)
      mgr.load
      mgr.list.should be_empty
    end
  end

  it "installs from a local path" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        File.write(File.join(source, "kimi.plugin.json"), %({"name":"test-plugin","version":"1.0"}))
        Dir.mkdir(File.join(source, "skills"))
        Dir.mkdir(File.join(source, "skills", "my-skill"))
        File.write(File.join(source, "skills", "my-skill", "SKILL.md"), "# My Skill\n\nDo stuff")

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        record = mgr.install(source)
        record.id.should eq("test-plugin")
        record.display_name.should eq("test-plugin")
        record.version.should eq("1.0")
        record.ok?.should be_true

        mgr.list.size.should eq(1)
      end
    end
  end

  it "persists and reloads installed plugins" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        File.write(File.join(source, "kimi.plugin.json"), %({"name":"persist-test"}))

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)

        # New manager instance reads from disk
        mgr2 = Hcode::Plugin::Manager.new(home)
        mgr2.load
        mgr2.list.size.should eq(1)
        mgr2.list[0].id.should eq("persist-test")
      end
    end
  end

  it "enables and disables a plugin" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        File.write(File.join(source, "kimi.plugin.json"), %({"name":"toggle-test"}))

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        record = mgr.install(source)
        record.enabled?.should be_true

        mgr.set_enabled("toggle-test", false)
        mgr.get("toggle-test").try(&.enabled?).should be_false

        mgr.set_enabled("toggle-test", true)
        mgr.get("toggle-test").try(&.enabled?).should be_true
      end
    end
  end

  it "removes a plugin" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        File.write(File.join(source, "kimi.plugin.json"), %({"name":"remove-test"}))

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)
        mgr.list.size.should eq(1)

        mgr.remove("remove-test")
        mgr.list.should be_empty
      end
    end
  end

  it "returns plugin skills for enabled plugins" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        File.write(File.join(source, "kimi.plugin.json"), %({"name":"skill-plugin","skills":["./skills/"]}))
        Dir.mkdir(File.join(source, "skills"))
        Dir.mkdir(File.join(source, "skills", "work"))
        File.write(File.join(source, "skills", "work", "SKILL.md"), "# Work\n\nDo work")

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)

        skills = mgr.plugin_skills
        skills.size.should eq(1)
        skills[0].name.should eq("work")
      end
    end
  end

  it "returns no skills for disabled plugins" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        File.write(File.join(source, "kimi.plugin.json"), %({"name":"disabled-plugin","skills":["./skills/"]}))
        Dir.mkdir(File.join(source, "skills"))
        Dir.mkdir(File.join(source, "skills", "work"))
        File.write(File.join(source, "skills", "work", "SKILL.md"), "# Work")

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)
        mgr.set_enabled("disabled-plugin", false)

        mgr.plugin_skills.should be_empty
      end
    end
  end

  it "returns enabled session starts" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        manifest = {
          "name"         => "session-start-plugin",
          "sessionStart" => {"skill" => "init-skill"},
        }
        File.write(File.join(source, "kimi.plugin.json"), manifest.to_json)

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)

        starts = mgr.enabled_session_starts
        starts.size.should eq(1)
        starts[0].plugin_id.should eq("session-start-plugin")
        starts[0].skill_name.should eq("init-skill")
      end
    end
  end

  it "returns enabled MCP servers namespaced as plugin-<id>:<name>" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        manifest = {
          "name"       => "mcp-plugin",
          "mcpServers" => {
            "api" => {"command" => "node", "args" => ["server.js"]},
          },
        }
        File.write(File.join(source, "kimi.plugin.json"), manifest.to_json)

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)

        servers = mgr.enabled_mcp_servers
        servers.size.should eq(1)
        servers[0].name.should eq("plugin-mcp-plugin:api")
        servers[0].command.should eq("node")
      end
    end
  end

  it "returns enabled hooks with plugin root as cwd" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        manifest = {
          "name"  => "hooks-plugin",
          "hooks" => [{"event" => "PreToolUse", "command" => "echo check"}],
        }
        File.write(File.join(source, "kimi.plugin.json"), manifest.to_json)

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        record = mgr.install(source)

        hooks = mgr.enabled_hooks
        hooks.size.should eq(1)
        hooks[0].event.should eq("PreToolUse")
        hooks[0].cwd.should eq(record.root)
        hooks[0].env.try(&.["KIMI_PLUGIN_ROOT"]).should eq(record.root)
      end
    end
  end

  it "returns enabled commands" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        Dir.mkdir(File.join(source, "commands"))
        File.write(File.join(source, "commands", "report.md"), "---\ndescription: Report\n---\nReport body")
        manifest = {"name" => "cmd-plugin", "commands" => "./commands/"}
        File.write(File.join(source, "kimi.plugin.json"), manifest.to_json)

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)

        commands = mgr.enabled_commands
        commands.size.should eq(1)
        commands[0].name.should eq("report")
        commands[0].plugin_id.should eq("cmd-plugin")
      end
    end
  end

  it "toggles individual MCP server enable state" do
    with_tmpdir do |home|
      with_tmpdir do |source|
        manifest = {
          "name"       => "mcp-toggle",
          "mcpServers" => {
            "srv1" => {"command" => "node"},
          },
        }
        File.write(File.join(source, "kimi.plugin.json"), manifest.to_json)

        mgr = Hcode::Plugin::Manager.new(home)
        mgr.load
        mgr.install(source)

        mgr.enabled_mcp_servers.size.should eq(1)

        mgr.set_mcp_server_enabled("mcp-toggle", "srv1", false)
        mgr.enabled_mcp_servers.should be_empty
      end
    end
  end
end
