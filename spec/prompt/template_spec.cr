require "../spec_helper"

describe H2code::Prompt::Template do
  it "substitutes variables" do
    result = H2code::Prompt::Template.render(
      "Hello {{name}}!",
      {"name" => "World"},
    )
    result.should eq("Hello World!")
  end

  it "supports spaced variable syntax" do
    result = H2code::Prompt::Template.render(
      "Hello {{ name }}!",
      {"name" => "World"},
    )
    result.should eq("Hello World!")
  end

  it "throws on undefined variables" do
    expect_raises(Exception, /Undefined template variables/) do
      H2code::Prompt::Template.render("Hello {{missing}}!", {} of String => String)
    end
  end

  it "processes {% if VAR %} blocks when VAR is non-empty" do
    result = H2code::Prompt::Template.render(
      "{% if SHOW %}visible{% endif %}",
      {"SHOW" => "yes"},
    )
    result.should contain("visible")
  end

  it "skips {% if VAR %} blocks when VAR is empty" do
    result = H2code::Prompt::Template.render(
      "before{% if HIDDEN %}hidden{% endif %}after",
      {"HIDDEN" => ""},
    )
    result.should eq("beforeafter")
  end

  it "supports {% if VAR == \"value\" %} conditionals" do
    result = H2code::Prompt::Template.render(
      "{% if OS == \"Linux\" %}linux{% endif %}",
      {"OS" => "Linux"},
    )
    result.should contain("linux")

    result2 = H2code::Prompt::Template.render(
      "{% if OS == \"Linux\" %}linux{% endif %}",
      {"OS" => "macOS"},
    )
    result2.should eq("")
  end

  it "supports {% if VAR != \"value\" %} conditionals" do
    result = H2code::Prompt::Template.render(
      "{% if OS != \"Windows\" %}unix{% endif %}",
      {"OS" => "Linux"},
    )
    result.should contain("unix")
  end

  it "supports {% else %} in conditionals" do
    result = H2code::Prompt::Template.render(
      "{% if EMPTY %}yes{% else %}no{% endif %}",
      {"EMPTY" => ""},
    )
    result.should contain("no")
  end
end

describe H2code::Prompt::SystemPrompt do
  it ".build includes key behavioral instructions from the JS system prompt" do
    prompt = H2code::Prompt::SystemPrompt.build(Dir.current)

    prompt.should contain("HIGHLY RECOMMENDED to make them in parallel")
    prompt.should contain("Write in the user's language")
    prompt.should contain("<system-reminder>")
    prompt.should contain("Date and Time")
    prompt.should contain("Ultimate Reminders")
    prompt.should contain("keep it stupidly simple")
    prompt.should contain(Dir.current)
  end

  it ".build includes OS and shell information" do
    prompt = H2code::Prompt::SystemPrompt.build(Dir.current)

    prompt.should contain("Operating System")
    prompt.should contain("Working Directory")
  end

  it ".build omits the Additional Directories section when no dirs given" do
    prompt = H2code::Prompt::SystemPrompt.build(Dir.current)

    prompt.should_not contain("## Additional Directories")
  end

  it ".build includes Additional Directories listing when dirs are provided" do
    tmp = Dir.tempdir
    prompt = H2code::Prompt::SystemPrompt.build(Dir.current, additional_dirs: [tmp])

    prompt.should contain("## Additional Directories")
    prompt.should contain(tmp)
  end

  it ".identity_block names the model and provider while keeping the H2Code identity" do
    block = H2code::Prompt::SystemPrompt.identity_block("moonshot", "kimi-for-coding")

    block.should contain("# Identity")
    block.should contain("kimi-for-coding")
    block.should contain("moonshot")
    block.should contain("identify as H2Code")
    block.should_not contain("{{")
  end
end
