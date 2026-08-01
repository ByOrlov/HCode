require "../spec_helper"

describe Hcode::Plugin::SourceResolver do
  it "resolves local absolute path" do
    result = Hcode::Plugin::SourceResolver.resolve("/home/user/my-plugin")
    result.kind.local_path?.should be_true
    result.path.should eq("/home/user/my-plugin")
  end

  it "resolves zip URL" do
    result = Hcode::Plugin::SourceResolver.resolve("https://example.com/plugin.zip")
    result.kind.zip_url?.should be_true
    result.path.should eq("https://example.com/plugin.zip")
  end

  it "resolves bare GitHub URL" do
    result = Hcode::Plugin::SourceResolver.resolve("https://github.com/owner/repo")
    result.kind.github?.should be_true
    gh = result.github.should_not be_nil
    gh.owner.should eq("owner")
    gh.repo.should eq("repo")
    gh.ref.should be_nil
  end

  it "resolves GitHub tree branch URL" do
    result = Hcode::Plugin::SourceResolver.resolve("https://github.com/owner/repo/tree/main")
    result.kind.github?.should be_true
    gh = result.github.should_not be_nil
    gh.owner.should eq("owner")
    gh.repo.should eq("repo")
    ref = gh.ref.should_not be_nil
    ref.kind.should eq("branch")
    ref.value.should eq("main")
  end

  it "resolves GitHub tree SHA URL" do
    result = Hcode::Plugin::SourceResolver.resolve("https://github.com/owner/repo/tree/abc1234")
    result.kind.github?.should be_true
    gh = result.github.should_not be_nil
    ref = gh.ref.should_not be_nil
    ref.kind.should eq("sha")
    ref.value.should eq("abc1234")
  end

  it "resolves GitHub release tag URL" do
    result = Hcode::Plugin::SourceResolver.resolve("https://github.com/owner/repo/releases/tag/v1.0.0")
    result.kind.github?.should be_true
    gh = result.github.should_not be_nil
    ref = gh.ref.should_not be_nil
    ref.kind.should eq("tag")
    ref.value.should eq("v1.0.0")
  end

  it "resolves GitHub commit URL" do
    result = Hcode::Plugin::SourceResolver.resolve("https://github.com/owner/repo/commit/abc123def456")
    result.kind.github?.should be_true
    gh = result.github.should_not be_nil
    ref = gh.ref.should_not be_nil
    ref.kind.should eq("sha")
    ref.value.should eq("abc123def456")
  end

  it "strips .git suffix from repo name" do
    result = Hcode::Plugin::SourceResolver.resolve("https://github.com/owner/repo.git")
    gh = result.github.should_not be_nil
    gh.repo.should eq("repo")
  end

  it "throws on non-absolute relative path" do
    expect_raises(Exception, "Plugin root must be an absolute path") do
      Hcode::Plugin::SourceResolver.resolve("relative/path")
    end
  end
end
