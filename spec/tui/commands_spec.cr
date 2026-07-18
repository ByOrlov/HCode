require "../spec_helper"

describe Hcode::TUI::CommandRegistry do
  describe ".parse" do
    it "parses command without args" do
      result = Hcode::TUI::CommandRegistry.parse("/help")
      result.should_not be_nil
      result.not_nil!.command.should eq("/help")
      result.not_nil!.args.should eq("")
    end

    it "parses command with args" do
      result = Hcode::TUI::CommandRegistry.parse("/add-dir /tmp/foo")
      result.should_not be_nil
      result.not_nil!.command.should eq("/add-dir")
      result.not_nil!.args.should eq("/tmp/foo")
    end

    it "returns nil for non-command input" do
      result = Hcode::TUI::CommandRegistry.parse("hello world")
      result.should be_nil
    end
  end

  describe ".match" do
    it "matches commands by prefix" do
      matches = Hcode::TUI::CommandRegistry.match("/c")
      matches.map(&.name).should contain("/clear")
      matches.map(&.name).should contain("/compact")
    end

    it "returns empty for no match" do
      matches = Hcode::TUI::CommandRegistry.match("/xyz")
      matches.should be_empty
    end

    it "returns empty for empty prefix" do
      matches = Hcode::TUI::CommandRegistry.match("")
      matches.should be_empty
    end

    it "matches single command exactly" do
      matches = Hcode::TUI::CommandRegistry.match("/help")
      matches.size.should eq(1)
      matches[0].name.should eq("/help")
    end
  end

  describe ".find" do
    it "finds existing command" do
      cmd = Hcode::TUI::CommandRegistry.find("/exit")
      cmd.should_not be_nil
      cmd.not_nil!.name.should eq("/exit")
    end

    it "returns nil for unknown command" do
      Hcode::TUI::CommandRegistry.find("/unknown").should be_nil
    end
  end

  describe ".names" do
    it "includes all command names" do
      names = Hcode::TUI::CommandRegistry.names
      names.should contain("/help")
      names.should contain("/exit")
      names.should contain("/compact")
    end

    it "includes the session management commands" do
      names = Hcode::TUI::CommandRegistry.names
      names.should contain("/sessions")
      names.should contain("/resume")
      names.should contain("/fork")
      names.should contain("/archive")
      names.should contain("/restore")
      names.should contain("/rename")
      names.should contain("/title")
    end
  end
end
