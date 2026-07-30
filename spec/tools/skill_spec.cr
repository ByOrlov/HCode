require "../spec_helper"
require "../../src/tools/skill"

private def make_skill(name, content, **opts)
  Hcode::Tools::SkillDefinition.new(
    name: name,
    content: content,
    metadata: Hcode::Tools::SkillMetadata.new(
      type: opts[:type]?,
      arguments: opts[:arguments]?,
      disable_model_invocation: opts[:disable_model_invocation]? || false
    ),
    path: opts[:path]?
  )
end

describe Hcode::Tools::Skill do
  after_each do
    Hcode::Tools::Skill.catalog = nil
    Hcode::Tools::Skill.memory = nil
    Hcode::Tools::Skill.current_depth = 0
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::Skill.new
    tool.name.should eq("Skill")
    tool.description.should contain("BLOCKING REQUIREMENT")

    props = tool.parameters["properties"].as_h
    props.has_key?("skill").should be_true
    props.has_key?("args").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["skill"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "fails when catalog is missing" do
    tool = Hcode::Tools::Skill.new
    result = tool.execute(JSON.parse(%({ "skill": "commit" })))
    result.is_error.should be_true
    result.content.should contain("catalog is not initialized")
  end

  it "fails when skill is not found" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new
    tool = Hcode::Tools::Skill.new
    result = tool.execute(JSON.parse(%({ "skill": "missing" })))
    result.is_error.should be_true
    result.content.should contain(%(Skill "missing" not found))
  end

  it "fails when model invocation is disabled" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([
      make_skill("commit", "content", disable_model_invocation: true)
    ])
    tool = Hcode::Tools::Skill.new
    result = tool.execute(JSON.parse(%({ "skill": "commit" })))
    result.is_error.should be_true
    result.content.should contain("can only be triggered by the user")
  end

  it "fails when type is not inline (e.g. flow)" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([
      make_skill("flow", "content", type: "flow")
    ])
    tool = Hcode::Tools::Skill.new
    result = tool.execute(JSON.parse(%({ "skill": "flow" })))
    result.is_error.should be_true
    result.content.should contain("not an inline skill")
  end

  it "succeeds for default (prompt) skill type" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([
      make_skill("commit", "Commit the changes.")
    ])
    tool = Hcode::Tools::Skill.new
    result = tool.execute(JSON.parse(%({ "skill": "commit" })))
    result.is_error.should be_false
    result.content.should contain(%(loaded inline))
  end

  it "injects rendered block into memory" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([
      make_skill("commit", "Commit it now.", path: "/tmp/skills/commit.md")
    ])
    memory = Hcode::Context::Memory.new
    Hcode::Tools::Skill.memory = memory

    tool = Hcode::Tools::Skill.new
    tool.execute(JSON.parse(%({ "skill": "commit" })))

    memory.history.size.should be > 0
    injected = memory.history.find(&.origin.injection?)
    injected.should_not be_nil
    text = injected.not_nil!.message.content.to_s
    text.should contain("<hcode-skill-loaded")
    text.should contain(%(name="commit"))
    text.should contain(%(trigger="model-tool"))
    text.should contain(%(source="project"))
    text.should contain("Commit it now.")
  end

  it "substitutes $1 and $ARGUMENTS placeholders" do
    skill = make_skill("greet", "Hello $1! Args: $ARGUMENTS", arguments: ["name"])
    catalog = Hcode::Tools::InMemorySkillCatalog.new([skill])
    Hcode::Tools::Skill.catalog = catalog

    renderer = Hcode::Tools::Skill.new
    rendered = catalog.render_skill_prompt(skill, "world extra", nil)
    rendered.should contain("Hello world")
    rendered.should contain("Args: world extra")
  end

  it "substitutes $NAME via metadata.arguments" do
    skill = make_skill("deploy", "Deploying $env", arguments: "env")
    catalog = Hcode::Tools::InMemorySkillCatalog.new([skill])
    Hcode::Tools::Skill.catalog = catalog

    rendered = catalog.render_skill_prompt(skill, "production", nil)
    rendered.should contain("Deploying production")
  end

  it "appends ARGUMENTS: line when no placeholder in body" do
    skill = make_skill("ping", "Pong. No placeholders here.")
    catalog = Hcode::Tools::InMemorySkillCatalog.new([skill])
    Hcode::Tools::Skill.catalog = catalog

    rendered = catalog.render_skill_prompt(skill, "with extra info", nil)
    rendered.should contain("Pong.")
    rendered.should contain("ARGUMENTS: with extra info")
  end

  it "escapes XML special chars in skill attributes" do
    skill = make_skill("x", "content", path: "/tmp/x.md")
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([skill])
    memory = Hcode::Context::Memory.new
    Hcode::Tools::Skill.memory = memory

    tool = Hcode::Tools::Skill.new
    tool.execute(JSON.parse(%q({ "skill": "x", "args": "a<b>&c\"d" })))

    text = memory.history.find(&.origin.injection?).not_nil!.message.content.to_s
    text.should contain(%(args="a&lt;b&gt;&amp;c&quot;d"))
  end

  it "tokenizes quoted arguments correctly" do
    renderer = Hcode::Tools::Skill.new
    tokens = renderer.tokenize_args(%(one "two words" 'three' four))
    tokens.should eq(["one", "two words", "three", "four"])
  end

  it "rejects nested skill invocation past MAX_SKILL_QUERY_DEPTH" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([
      make_skill("x", "content")
    ])
    Hcode::Tools::Skill.current_depth = Hcode::Tools::Skill::MAX_SKILL_QUERY_DEPTH
    tool = Hcode::Tools::Skill.new
    expect_raises(Hcode::Tools::NestedSkillTooDeepError, /exceeded the maximum depth/) do
      tool.execute(JSON.parse(%({ "skill": "x" })))
    end
  end

  it "uses nested-skill trigger when depth > 0" do
    Hcode::Tools::Skill.catalog = Hcode::Tools::InMemorySkillCatalog.new([
      make_skill("x", "content", path: "/tmp/x.md")
    ])
    memory = Hcode::Context::Memory.new
    Hcode::Tools::Skill.memory = memory
    Hcode::Tools::Skill.current_depth = 1

    tool = Hcode::Tools::Skill.new
    tool.execute(JSON.parse(%({ "skill": "x" })))
    text = memory.history.find(&.origin.injection?).not_nil!.message.content.to_s
    text.should contain(%(trigger="nested-skill"))
  end
end

describe Hcode::Tools::Parser do
  it "parses frontmatter + body" do
    text = <<-MD
      ---
      name: commit
      description: Create a git commit
      when-to-use: after staging changes
      ---
      Run git status, then commit with a message.
      MD

    skill = Hcode::Tools::Parser.parse(text, "/proj/.agents/skills/commit/SKILL.md", "commit", "project")
    skill.name.should eq("commit")
    skill.description.should eq("Create a git commit")
    skill.when_to_use.should eq("after staging changes")
    skill.content.should contain("Run git status")
    skill.source.should eq("project")
  end

  it "falls back to directory name when name missing" do
    text = <<-MD
      ---
      description: no name field
      ---
      Body text.
      MD

    skill = Hcode::Tools::Parser.parse(text, "/x/foo/SKILL.md", "foo", "project")
    skill.name.should eq("foo")
  end

  it "parses arguments array" do
    text = <<-MD
      ---
      name: deploy
      arguments: ["env", "tag"]
      ---
      Deploy to $1.
      MD

    skill = Hcode::Tools::Parser.parse(text, "/x/deploy/SKILL.md", "deploy", "project")
    skill.metadata.arguments.should eq(["env", "tag"])
  end
end

describe Hcode::Tools::InMemorySkillCatalog do
  it "model_listing lists invocable skills" do
    cat = Hcode::Tools::InMemorySkillCatalog.new([
      Hcode::Tools::SkillDefinition.new(
        name: "commit",
        content: "git status",
        metadata: Hcode::Tools::SkillMetadata.new(description: "Create commit"),
        path: "/skills/commit/SKILL.md",
      ),
    ])
    listing = cat.model_listing
    listing.should contain("commit")
    listing.should contain("Create commit")
    listing.should contain("Path: /skills/commit/SKILL.md")
  end

  it "model_listing skips disabled skills" do
    cat = Hcode::Tools::InMemorySkillCatalog.new([
      Hcode::Tools::SkillDefinition.new(
        name: "hidden",
        content: "x",
        metadata: Hcode::Tools::SkillMetadata.new(
          description: "nope",
          disable_model_invocation: true,
        ),
      ),
    ])
    cat.model_listing.should eq("")
  end

  it "model_listing is empty when no skills" do
    cat = Hcode::Tools::InMemorySkillCatalog.new
    cat.model_listing.should eq("")
  end
end

describe Hcode::Tools::SkillDiscovery do
  it "discovers directory skills from a project root" do
    tmp = Dir.tempdir
    work = File.join(tmp, "hcode_skill_#{Random::Secure.hex(6)}")
    skill_dir = File.join(work, ".agents", "skills", "lint")
    Dir.mkdir_p(skill_dir)
    begin
      File.write(File.join(skill_dir, "SKILL.md"), <<-MD
        ---
        name: lint
        description: Run linters
        ---
        Run the project linter.
        MD
      )

      skills = Hcode::Tools::SkillDiscovery.discover("/nonexistent/home", work)
      skill = skills.find(&.name.==("lint"))
      skill.should_not be_nil
      skill.not_nil!.description.should eq("Run linters")
      skill.not_nil!.source.should eq("project")
    ensure
      FileUtils.rm_r(work) if Dir.exists?(work)
    end
  end

  it "discovers user-level skills from home" do
    tmp = Dir.tempdir
    home = File.join(tmp, "hcode_home_#{Random::Secure.hex(6)}")
    skill_dir = File.join(home, "skills", "fmt")
    Dir.mkdir_p(skill_dir)
    begin
      File.write(File.join(skill_dir, "SKILL.md"), <<-MD
        ---
        name: fmt
        description: Format code
        ---
        Format all files.
        MD
      )

      skills = Hcode::Tools::SkillDiscovery.discover(home, "/nonexistent/work")
      skills.any?(&.name.==("fmt")).should be_true
    ensure
      FileUtils.rm_r(home) if Dir.exists?(home)
    end
  end

  it "returns empty when no skill dirs exist" do
    skills = Hcode::Tools::SkillDiscovery.discover("/nonexistent/home", "/nonexistent/work")
    skills.should be_empty
  end
end
