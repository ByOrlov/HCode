require "../spec_helper"

describe Hcode::Prompt::Template do
  it "substitutes variables" do
    result = Hcode::Prompt::Template.render(
      "Hello {{name}}!",
      {"name" => "World"},
    )
    result.should eq("Hello World!")
  end

  it "supports spaced variable syntax" do
    result = Hcode::Prompt::Template.render(
      "Hello {{ name }}!",
      {"name" => "World"},
    )
    result.should eq("Hello World!")
  end

  it "throws on undefined variables" do
    expect_raises(Exception, /Undefined template variables/) do
      Hcode::Prompt::Template.render("Hello {{missing}}!", {} of String => String)
    end
  end

  it "processes {% if VAR %} blocks when VAR is non-empty" do
    result = Hcode::Prompt::Template.render(
      "{% if SHOW %}visible{% endif %}",
      {"SHOW" => "yes"},
    )
    result.should contain("visible")
  end

  it "skips {% if VAR %} blocks when VAR is empty" do
    result = Hcode::Prompt::Template.render(
      "before{% if HIDDEN %}hidden{% endif %}after",
      {"HIDDEN" => ""},
    )
    result.should eq("beforeafter")
  end

  it "supports {% if VAR == \"value\" %} conditionals" do
    result = Hcode::Prompt::Template.render(
      "{% if OS == \"Linux\" %}linux{% endif %}",
      {"OS" => "Linux"},
    )
    result.should contain("linux")

    result2 = Hcode::Prompt::Template.render(
      "{% if OS == \"Linux\" %}linux{% endif %}",
      {"OS" => "macOS"},
    )
    result2.should eq("")
  end

  it "supports {% if VAR != \"value\" %} conditionals" do
    result = Hcode::Prompt::Template.render(
      "{% if OS != \"Windows\" %}unix{% endif %}",
      {"OS" => "Linux"},
    )
    result.should contain("unix")
  end

  it "supports {% else %} in conditionals" do
    result = Hcode::Prompt::Template.render(
      "{% if EMPTY %}yes{% else %}no{% endif %}",
      {"EMPTY" => ""},
    )
    result.should contain("no")
  end
end

describe Hcode::Prompt::SystemPrompt do
  it ".build includes key behavioral instructions from the JS system prompt" do
    prompt = Hcode::Prompt::SystemPrompt.build(Dir.current)

    prompt.should contain("HIGHLY RECOMMENDED to make them in parallel")
    prompt.should contain("Write in the user's language")
    prompt.should contain("<system-reminder>")
    prompt.should contain("Date and Time")
    prompt.should contain("Ultimate Reminders")
    prompt.should contain("keep it stupidly simple")
    prompt.should contain(Dir.current)
  end

  it ".build includes OS and shell information" do
    prompt = Hcode::Prompt::SystemPrompt.build(Dir.current)

    prompt.should contain("Operating System")
    prompt.should contain("Working Directory")
  end

  it ".build omits the Additional Directories section when no dirs given" do
    prompt = Hcode::Prompt::SystemPrompt.build(Dir.current)

    prompt.should_not contain("## Additional Directories")
  end

  it ".build includes Additional Directories listing when dirs are provided" do
    tmp = Dir.tempdir
    prompt = Hcode::Prompt::SystemPrompt.build(Dir.current, additional_dirs: [tmp])

    prompt.should contain("## Additional Directories")
    prompt.should contain(tmp)
  end
end
