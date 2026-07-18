require "../spec_helper"
require "../../src/tools/select_tools"

describe Hcode::Tools::SelectTools do
  before_each do
    Hcode::Tools::ToolSelect.service = Hcode::Tools::InMemoryToolSelectService.new(
      loadable: ["a", "b", "c"],
      active: ["c"]
    )
  end
  after_each do
    Hcode::Tools::ToolSelect.service = nil
  end

  it "exposes snake_case JS-name and identical schema" do
    tool = Hcode::Tools::SelectTools.new
    tool.name.should eq("select_tools")
    props = tool.parameters["properties"].as_h
    props.has_key?("names").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["names"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "loads requested tools and reports already-available" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a", "b", "c"] })))
    result.is_error.should be_false
    result.content.should contain("Loaded: a, b")
    result.content.should contain("Already available: c")
  end

  it "reports unknown tools" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["x", "y"] })))
    result.is_error.should be_true
    result.content.should contain("Unknown tool: x.")
    result.content.should contain("Unknown tool: y.")
    result.content.should contain("Pick from the latest announced tools list")
  end

  it "partial case: mixed load + already-available + unknown" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a", "c", "z"] })))
    result.is_error.should be_false
    result.content.should contain("Loaded: a")
    result.content.should contain("Already available: c")
    result.content.should contain("Unknown tool: z.")
  end

  it "is_error true when only unknown" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["unknown_tool"] })))
    result.is_error.should be_true
  end

  it "is_error false when at least one loaded or already-available" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.is_error.should be_false
  end

  it "rejects empty names array" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": [] })))
    result.is_error.should be_true
    result.content.should contain("must be a non-empty array")
  end

  it "rejects missing names field" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_true
    result.content.should contain("must be a non-empty array")
  end

  it "filters out empty strings in names" do
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["", "a"] })))
    result.is_error.should be_false
    result.content.should contain("Loaded: a")
  end

  it "refuses when disabled" do
    service = Hcode::Tools::ToolSelect.service.not_nil!.as(Hcode::Tools::InMemoryToolSelectService)
    service.disable!
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.is_error.should be_true
    result.content.should contain("not available for the current model")
  end

  it "fails when no service is registered" do
    Hcode::Tools::ToolSelect.service = nil
    tool = Hcode::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.is_error.should be_true
    result.content.should contain("not initialized")
  end

  it "marks tools as active after successful load" do
    service = Hcode::Tools::ToolSelect.service.not_nil!.as(Hcode::Tools::InMemoryToolSelectService)
    tool = Hcode::Tools::SelectTools.new
    tool.execute(JSON.parse(%({ "names": ["a"] })))
    # Second call — a should now be already_available.
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.content.should contain("Already available: a")
    result.content.should_not contain("Loaded: a")
  end
end
