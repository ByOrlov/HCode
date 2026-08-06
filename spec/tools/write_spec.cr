require "../spec_helper"
require "file_utils"

describe Hcode::Tools::Write do
  it "creates a new file and reports UTF-8 bytes written" do
    path = "/tmp/hcode-test-write.txt"
    File.delete(path) if File.exists?(path)

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write.txt","content":"hello world\n"})))
    result.is_error?.should be_false
    result.content.should contain("Wrote 12 bytes")
    result.content.should contain("hcode-test-write.txt")

    File.read(path).should eq("hello world\n")
  end

  it "reports multi-byte UTF-8 byte count, not character count" do
    path = "/tmp/hcode-test-write-utf8.txt"
    File.delete(path) if File.exists?(path)

    tool = Hcode::Tools::Write.new("/tmp")
    # "héllo" is 6 UTF-8 bytes (h=1, é=2, l=1, l=1, o=1) + "\n" = 7 bytes,
    # but 6 characters if counted by size.
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-utf8.txt","content":"héllo\n"})))
    result.is_error?.should be_false
    result.content.should contain("Wrote 7 bytes")
  end

  it "overwrites an existing file completely" do
    path = "/tmp/hcode-test-write-over.txt"
    File.write(path, "old content\n")

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-over.txt","content":"new\n"})))
    result.is_error?.should be_false
    result.content.should contain("Wrote 4 bytes")

    File.read(path).should eq("new\n")
  end

  it "appends content to EOF without adding a newline" do
    path = "/tmp/hcode-test-write-append.txt"
    File.write(path, "first\n")

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-append.txt","content":"second","mode":"append"})))
    result.is_error?.should be_false
    result.content.should contain("Appended 6 bytes")

    File.read(path).should eq("first\nsecond")
  end

  it "reports zero bytes for empty content" do
    path = "/tmp/hcode-test-write-empty.txt"
    File.delete(path) if File.exists?(path)

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-empty.txt","content":""})))
    result.is_error?.should be_false
    result.content.should contain("Wrote 0 bytes")

    File.read(path).should eq("")
  end

  it "creates missing parent directories automatically" do
    path = "/tmp/hcode-test-write-nested/deep/sub/file.txt"
    FileUtils.rm_rf("/tmp/hcode-test-write-nested") if Dir.exists?("/tmp/hcode-test-write-nested")

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-nested/deep/sub/file.txt","content":"nested\n"})))
    result.is_error?.should be_false
    File.read(path).should eq("nested\n")
  end

  it "errors when the parent path exists but is not a directory" do
    blocker = "/tmp/hcode-test-write-blocker"
    File.write(blocker, "not a dir\n")

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-blocker/child.txt","content":"x"})))
    result.is_error?.should be_true
    result.content.should contain("not a directory")
    result.content.should contain("hcode-test-write-blocker")
  end

  it "blocks writes to sensitive files (.env)" do
    path = "/tmp/hcode-test-write-envdir/.env"
    FileUtils.rm_rf("/tmp/hcode-test-write-envdir") if Dir.exists?("/tmp/hcode-test-write-envdir")

    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"hcode-test-write-envdir/.env","content":"SECRET=1"})))
    result.is_error?.should be_true
    result.content.should contain("sensitive")
    File.exists?(path).should be_false
  end

  it "blocks relative paths that escape the working directory" do
    tool = Hcode::Tools::Write.new("/tmp")
    result = tool.execute(JSON.parse(%q({"path":"../escape.txt","content":"x"})))
    result.is_error?.should be_true
    result.content.should contain("outside")
  end
end
