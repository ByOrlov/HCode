require "../spec_helper"

describe Hcode::Plugin::ManifestParser do
  it "parses a valid manifest with all fields" do
    with_tmpdir do |dir|
      manifest = {
        "name"        => "my-plugin",
        "version"     => "1.0.0",
        "description" => "A test plugin",
        "keywords"    => ["test", "demo"],
        "author"      => {"name" => "Test", "email" => "test@test.com"},
        "interface"   => {
          "displayName"      => "My Plugin",
          "shortDescription" => "Short desc",
        },
      }
      File.write(File.join(dir, "kimi.plugin.json"), manifest.to_json)

      result = Hcode::Plugin::ManifestParser.parse(dir)
      result.has_error?.should be_false
      m = result.manifest.should_not be_nil

      m.name.should eq("my-plugin")
      m.version.should eq("1.0.0")
      m.description.should eq("A test plugin")
      m.keywords.should eq(["test", "demo"])
      m.author.try(&.name).should eq("Test")
      m.interface.try(&.display_name).should eq("My Plugin")
    end
  end

  it "errors when name is missing" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "kimi.plugin.json"), %({"description": "no name"}))
      result = Hcode::Plugin::ManifestParser.parse(dir)
      result.manifest.should be_nil
      result.has_error?.should be_true
      result.diagnostics.any?(&.message.includes?("\"name\" is required")).should be_true
    end
  end

  it "errors when name does not match regex" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "kimi.plugin.json"), %({"name": "Bad Name!"}))
      result = Hcode::Plugin::ManifestParser.parse(dir)
      result.manifest.should be_nil
      result.diagnostics.any?(&.message.includes?("must match")).should be_true
    end
  end

  it "auto-detects root SKILL.md when skills absent" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "kimi.plugin.json"), %({"name": "auto-skill"}))
      File.write(File.join(dir, "SKILL.md"), "# My Skill\n\nInstructions")
      result = Hcode::Plugin::ManifestParser.parse(dir)
      m = result.manifest.should_not be_nil
      m.skills.should eq([dir])
    end
  end

  it "errors when no manifest file found" do
    with_tmpdir do |dir|
      result = Hcode::Plugin::ManifestParser.parse(dir)
      result.manifest.should be_nil
      result.diagnostics.any?(&.message.includes?("No manifest")).should be_true
    end
  end

  it "parses mcpServers with stdio transport" do
    with_tmpdir do |dir|
      manifest = {
        "name"       => "mcp-plugin",
        "mcpServers" => {
          "server1" => {
            "command" => "node",
            "args"    => ["server.js"],
          },
        },
      }
      File.write(File.join(dir, "kimi.plugin.json"), manifest.to_json)

      result = Hcode::Plugin::ManifestParser.parse(dir)
      m = result.manifest.should_not be_nil
      m.mcp_servers.size.should eq(1)
      cfg = m.mcp_servers["server1"]
      cfg.command.should eq("node")
      cfg.args.should eq(["server.js"])
    end
  end

  it "parses hooks" do
    with_tmpdir do |dir|
      manifest = {
        "name"  => "hooks-plugin",
        "hooks" => [
          {"event" => "PreToolUse", "matcher" => "Bash", "command" => "echo check"},
        ],
      }
      File.write(File.join(dir, "kimi.plugin.json"), manifest.to_json)

      result = Hcode::Plugin::ManifestParser.parse(dir)
      m = result.manifest.should_not be_nil
      m.hooks.size.should eq(1)
      m.hooks[0].event.should eq("PreToolUse")
      m.hooks[0].command.should eq("echo check")
    end
  end

  it "parses commands from directory" do
    with_tmpdir do |dir|
      cmds = File.join(dir, "commands")
      Dir.mkdir(cmds)
      File.write(File.join(cmds, "report.md"), "---\ndescription: A report\n---\nBody")
      manifest = {"name" => "cmd-plugin", "commands" => "./commands/"}
      File.write(File.join(dir, "kimi.plugin.json"), manifest.to_json)

      result = Hcode::Plugin::ManifestParser.parse(dir)
      m = result.manifest.should_not be_nil
      m.commands.size.should eq(1)
      m.commands[0].name.should eq("report")
    end
  end

  it "records unsupported runtime fields as info diagnostics" do
    with_tmpdir do |dir|
      manifest = {"name" => "test", "tools" => ["some-tool"]}
      File.write(File.join(dir, "kimi.plugin.json"), manifest.to_json)

      result = Hcode::Plugin::ManifestParser.parse(dir)
      result.diagnostics.any? { |d|
        d.severity.info? && d.message.includes?("\"tools\"")
      }.should be_true
    end
  end
end
