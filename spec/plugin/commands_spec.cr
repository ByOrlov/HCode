require "../spec_helper"

describe H2code::Plugin::CommandLoader do
  it "parses command with frontmatter" do
    text = "---\nname: report\ndescription: Generate report\n---\nGenerate a report for $ARGUMENTS"
    cmd = H2code::Plugin::CommandLoader.parse_command_text(text, "/path/report.md", "my-plugin", "fallback")
    cmd.name.should eq("report")
    cmd.description.should eq("Generate report")
    cmd.body.should eq("Generate a report for $ARGUMENTS")
    cmd.plugin_id.should eq("my-plugin")
  end

  it "falls back to fallback_name when no frontmatter name" do
    text = "---\ndescription: Test\n---\nBody"
    cmd = H2code::Plugin::CommandLoader.parse_command_text(text, "/path/cmd.md", "plugin", "fallback-name")
    cmd.name.should eq("fallback-name")
  end

  it "falls back to basename when no frontmatter and no fallback" do
    text = "Just a body"
    cmd = H2code::Plugin::CommandLoader.parse_command_text(text, "/path/my-cmd.md", "plugin", nil)
    cmd.name.should eq("my-cmd")
  end

  it "derives description from first line of body" do
    text = "This is the first line\nSecond line"
    cmd = H2code::Plugin::CommandLoader.parse_command_text(text, "/path/x.md", "plugin", nil)
    cmd.description.should eq("This is the first line")
  end

  it "expands $ARGUMENTS placeholder" do
    body = "Run analysis on $ARGUMENTS"
    result = H2code::Plugin::CommandLoader.expand_arguments(body, "TSLA")
    result.should eq("Run analysis on TSLA")
  end

  it "appends arguments when no placeholder" do
    body = "Fixed prompt"
    result = H2code::Plugin::CommandLoader.expand_arguments(body, "extra args")
    result.should eq("Fixed prompt\n\nARGUMENTS: extra args")
  end

  it "leaves body unchanged when no placeholder and no args" do
    body = "Fixed prompt"
    result = H2code::Plugin::CommandLoader.expand_arguments(body, "")
    result.should eq("Fixed prompt")
  end
end
