require "../spec_helper"

describe Kimi::Prompt::Template do
  it "substitutes variables" do
    result = Kimi::Prompt::Template.render(
      "Hello {{name}}!",
      {"name" => "World"},
    )
    result.should eq("Hello World!")
  end

  it "supports spaced variable syntax" do
    result = Kimi::Prompt::Template.render(
      "Hello {{ name }}!",
      {"name" => "World"},
    )
    result.should eq("Hello World!")
  end

  it "throws on undefined variables" do
    expect_raises(Exception, /Undefined template variables/) do
      Kimi::Prompt::Template.render("Hello {{missing}}!", {} of String => String)
    end
  end

  it "processes {% if VAR %} blocks when VAR is non-empty" do
    result = Kimi::Prompt::Template.render(
      "{% if SHOW %}visible{% endif %}",
      {"SHOW" => "yes"},
    )
    result.should contain("visible")
  end

  it "skips {% if VAR %} blocks when VAR is empty" do
    result = Kimi::Prompt::Template.render(
      "before{% if HIDDEN %}hidden{% endif %}after",
      {"HIDDEN" => ""},
    )
    result.should eq("beforeafter")
  end

  it "supports {% if VAR == \"value\" %} conditionals" do
    result = Kimi::Prompt::Template.render(
      "{% if OS == \"Linux\" %}linux{% endif %}",
      {"OS" => "Linux"},
    )
    result.should contain("linux")

    result2 = Kimi::Prompt::Template.render(
      "{% if OS == \"Linux\" %}linux{% endif %}",
      {"OS" => "macOS"},
    )
    result2.should eq("")
  end

  it "supports {% if VAR != \"value\" %} conditionals" do
    result = Kimi::Prompt::Template.render(
      "{% if OS != \"Windows\" %}unix{% endif %}",
      {"OS" => "Linux"},
    )
    result.should contain("unix")
  end

  it "supports {% else %} in conditionals" do
    result = Kimi::Prompt::Template.render(
      "{% if EMPTY %}yes{% else %}no{% endif %}",
      {"EMPTY" => ""},
    )
    result.should contain("no")
  end
end

describe Kimi::Prompt::SystemPrompt do
  it ".build includes key behavioral instructions from the JS system prompt" do
    prompt = Kimi::Prompt::SystemPrompt.build(Dir.current)

    prompt.should contain("HIGHLY RECOMMENDED to make them in parallel")
    prompt.should contain("Write in the user's language")
    prompt.should contain("<system-reminder>")
    prompt.should contain("Date and Time")
    prompt.should contain("Ultimate Reminders")
    prompt.should contain("keep it stupidly simple")
    prompt.should contain(Dir.current)
  end

  it ".build includes OS and shell information" do
    prompt = Kimi::Prompt::SystemPrompt.build(Dir.current)

    prompt.should contain("Operating System")
    prompt.should contain("Working Directory")
  end
end
