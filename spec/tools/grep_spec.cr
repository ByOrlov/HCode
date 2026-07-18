require "../spec_helper"

describe Kimi::Tools::Grep do
  # Shared test directory — created once, cleaned up at the end.
  test_dir = "/tmp/kimi-test-grep"
  FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
  Dir.mkdir_p(test_dir)

  before_all do
    FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
    Dir.mkdir_p(test_dir)
  end

  after_all do
    FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
  end

  it "returns error for empty pattern" do
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({})))
    result.is_error.should be_true
  end

  it "searches content and returns matching lines" do
    File.write(File.join(test_dir, "a.txt"), "hello world\nfoo bar\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "hello", "output_mode": "content"})))
    result.is_error.should be_false
    result.content.should contain("hello world")
    result.content.should_not contain("foo bar")
  end

  it "defaults to files_with_matches mode" do
    File.write(File.join(test_dir, "b.txt"), "searchterm here\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "searchterm"})))
    result.is_error.should be_false
    result.content.should contain("b.txt")
    result.content.should_not contain("searchterm here")
  end

  it "supports count_matches mode" do
    File.write(File.join(test_dir, "c.txt"), "dup\ndup\ndup\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "dup", "output_mode": "count_matches"})))
    result.is_error.should be_false
    result.content.should contain("Found")
    result.content.should contain("occurrence")
  end

  it "supports case-insensitive search with -i" do
    File.write(File.join(test_dir, "d.txt"), "Hello World\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "hello", "output_mode": "content", "-i": true})))
    result.is_error.should be_false
    result.content.should contain("Hello World")
  end

  it "supports context lines with -A" do
    File.write(File.join(test_dir, "e.txt"), "line1\nMATCH\nline3\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "MATCH", "output_mode": "content", "-A": 1})))
    result.is_error.should be_false
    result.content.should contain("MATCH")
    result.content.should contain("line3")
  end

  it "supports context lines with -B" do
    File.write(File.join(test_dir, "f.txt"), "line1\nMATCH\nline3\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "MATCH", "output_mode": "content", "-B": 1})))
    result.is_error.should be_false
    result.content.should contain("line1")
    result.content.should contain("MATCH")
  end

  it "supports glob filter" do
    File.write(File.join(test_dir, "g.cr"), "crystal_match\n")
    File.write(File.join(test_dir, "g.txt"), "crystal_match\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "crystal_match", "glob": "*.cr"})))
    result.is_error.should be_false
    result.content.should contain("g.cr")
    result.content.should_not contain("g.txt")
  end

  it "filters sensitive files" do
    File.write(File.join(test_dir, ".env"), "SECRET_KEY=hunter2\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "SECRET_KEY", "output_mode": "content"})))
    result.is_error.should be_false
    result.content.should_not contain("hunter2")
    result.content.should_not contain("SECRET_KEY")
  end

  it "filters .env files even in files_with_matches mode" do
    File.write(File.join(test_dir, ".env.local"), "API_TOKEN=xyz\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "API_TOKEN"})))
    result.is_error.should be_false
    # Content must never leak, but the filtered-file notice (listing the path) is expected.
    result.content.should_not contain("xyz")
  end

  it "excludes VCS metadata directories" do
    vcs_dir = File.join(test_dir, ".git")
    Dir.mkdir_p(vcs_dir)
    File.write(File.join(vcs_dir, "config"), "vcs_secret_data\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "vcs_secret_data"})))
    result.is_error.should be_false
    result.content.should_not contain("vcs_secret_data")
  end

  it "supports head_limit for pagination" do
    File.write(File.join(test_dir, "h.txt"), "pagetest\npagetest\npagetest\npagetest\npagetest\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "pagetest", "output_mode": "content", "head_limit": 2})))
    result.is_error.should be_false
    result.content.should contain("truncated")
  end

  it "supports offset for pagination" do
    File.write(File.join(test_dir, "i.txt"), "offsetline\noffsetline\noffsetline\noffsetline\noffsetline\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "offsetline", "output_mode": "content", "head_limit": 0})))
    result.is_error.should be_false
    result.content.should_not contain("truncated")
  end

  it "returns no matches message for non-existent pattern" do
    File.write(File.join(test_dir, "j.txt"), "some content\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "ZZZ_NOT_FOUND_ZZZ", "output_mode": "content"})))
    result.is_error.should be_false
    result.content.should contain("No matches")
  end

  it "supports include_ignored to search gitignored files" do
    Dir.mkdir_p(test_dir)
    File.write(File.join(test_dir, ".gitignore"), "ignored_file.txt\n")
    File.write(File.join(test_dir, "ignored_file.txt"), "ignored_content_here\n")
    grep = Kimi::Tools::Grep.new(test_dir)
    # Without include_ignored, the file is excluded by .gitignore
    result1 = grep.execute(JSON.parse(%({"pattern": "ignored_content_here"})))
    result1.content.should_not contain("ignored_file.txt")
    # With include_ignored, it should be found
    result2 = grep.execute(JSON.parse(%({"pattern": "ignored_content_here", "include_ignored": true})))
    result2.content.should contain("ignored_file.txt")
  end
end
