require "../spec_helper"

describe Hcode::Tools::Edit do
  it "replaces unique string" do
    path = "/tmp/hcode-test-edit.txt"
    File.write(path, "hello world\nfoo bar\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit.txt","old_string":"foo bar","new_string":"baz qux"})))
    result.is_error?.should be_false
    result.content.should contain("Edited")

    File.read(path).should eq("hello world\nbaz qux\n")
  end

  it "attaches a file_io display with before/after for rendering" do
    path = "/tmp/hcode-test-edit-disp.txt"
    File.write(path, "hello world\nfoo bar\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit-disp.txt","old_string":"foo bar","new_string":"baz qux"})))

    display = result.display
    display.should_not be_nil
    if display
      display.kind.should eq("file_io")
      display.operation.should eq("edit")
      display.path.should eq("hcode-test-edit-disp.txt")
      display.before.should eq("foo bar")
      display.after.should eq("baz qux")
    end
  end

  it "attaches display with replace_all too" do
    path = "/tmp/hcode-test-edit-disp2.txt"
    File.write(path, "dup\ndup\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit-disp2.txt","old_string":"dup","new_string":"x","replace_all":true})))

    display = result.display || raise "display should not be nil"
    display.operation.should eq("edit")
    display.before.should eq("dup")
    display.after.should eq("x")
  end

  it "does not attach display on error" do
    path = "/tmp/hcode-test-edit-disp3.txt"
    File.write(path, "hello\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit-disp3.txt","old_string":"missing","new_string":"x"})))

    result.is_error?.should be_true
    result.display.should be_nil
  end

  it "errors when old_string not found" do
    path = "/tmp/hcode-test-edit2.txt"
    File.write(path, "hello world\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit2.txt","old_string":"nonexistent","new_string":"x"})))
    result.is_error?.should be_true
    result.content.should contain("not found")
    result.content.should contain("Read Tool")
  end

  it "errors when old_string appears multiple times" do
    path = "/tmp/hcode-test-edit3.txt"
    File.write(path, "dup\ndup\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit3.txt","old_string":"dup","new_string":"x"})))
    result.is_error?.should be_true
    result.content.should contain("2 occurrences")
    result.content.should contain("replace_all=true")
  end

  it "errors when old_string equals new_string" do
    path = "/tmp/hcode-test-edit4.txt"
    File.write(path, "hello\n")

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit4.txt","old_string":"hello","new_string":"hello"})))
    result.is_error?.should be_true
    result.content.should contain("No changes")
  end

  it "errors when path is a directory" do
    dir = "/tmp/hcode-test-edit-dir"
    Dir.mkdir_p(dir)

    edit = Hcode::Tools::Edit.new("/tmp")
    result = edit.execute(JSON.parse(%({"path":"hcode-test-edit-dir","old_string":"x","new_string":"y"})))
    result.is_error?.should be_true
    result.content.should contain("not a file")
  end

  context "legacy camelCase fallback" do
    it "still accepts filePath / oldString / newString / replaceAll" do
      path = "/tmp/hcode-test-edit-legacy.txt"
      File.write(path, "hello world\nfoo bar\n")

      edit = Hcode::Tools::Edit.new("/tmp")
      result = edit.execute(JSON.parse(%({"filePath":"hcode-test-edit-legacy.txt","oldString":"foo bar","newString":"baz qux"})))
      result.is_error?.should be_false
      File.read(path).should eq("hello world\nbaz qux\n")
    end
  end

  context "replace_all" do
    it "replaces every occurrence when replace_all is true" do
      path = "/tmp/hcode-test-edit5.txt"
      File.write(path, "dup\ndup\ndup\n")

      edit = Hcode::Tools::Edit.new("/tmp")
      result = edit.execute(JSON.parse(%({"path":"hcode-test-edit5.txt","old_string":"dup","new_string":"x","replace_all":true})))
      result.is_error?.should be_false
      result.content.should contain("3 occurrences")

      File.read(path).should eq("x\nx\nx\n")
    end

    it "errors when replace_all finds no occurrence" do
      path = "/tmp/hcode-test-edit6.txt"
      File.write(path, "hello\n")

      edit = Hcode::Tools::Edit.new("/tmp")
      result = edit.execute(JSON.parse(%({"path":"hcode-test-edit6.txt","old_string":"missing","new_string":"x","replace_all":true})))
      result.is_error?.should be_true
      result.content.should contain("not found")
    end
  end

  context "CRLF normalization" do
    it "matches LF old_string against a pure CRLF file and writes CRLF back" do
      path = "/tmp/hcode-test-edit-crlf.txt"
      File.write(path, "hello world\r\nfoo bar\r\n")

      edit = Hcode::Tools::Edit.new("/tmp")
      result = edit.execute(JSON.parse(%({"path":"hcode-test-edit-crlf.txt","old_string":"foo bar","new_string":"baz qux"})))
      result.is_error?.should be_false

      File.read(path).should eq("hello world\r\nbaz qux\r\n")
    end

    it "preserves CRLF when replace_all rewrites a CRLF file" do
      path = "/tmp/hcode-test-edit-crlf2.txt"
      File.write(path, "dup\r\ndup\r\n")

      edit = Hcode::Tools::Edit.new("/tmp")
      result = edit.execute(JSON.parse(%({"path":"hcode-test-edit-crlf2.txt","old_string":"dup","new_string":"x","replace_all":true})))
      result.is_error?.should be_false

      File.read(path).should eq("x\r\nx\r\n")
    end
  end

  context "path access policy" do
    it "blocks editing a sensitive file (.env)" do
      Dir.mkdir_p("/tmp/hcode-test-edit-env")
      File.write("/tmp/hcode-test-edit-env/.env", "SECRET=1\n")

      edit = Hcode::Tools::Edit.new("/tmp/hcode-test-edit-env")
      result = edit.execute(JSON.parse(%({"path":".env","old_string":"SECRET=1","new_string":"SECRET=2"})))
      result.is_error?.should be_true
      result.content.should contain("sensitive-file pattern")
      result.content.should contain(".env")

      # File is untouched
      File.read("/tmp/hcode-test-edit-env/.env").should eq("SECRET=1\n")
    end

    it "blocks editing other SSH keys and credentials" do
      Dir.mkdir_p("/tmp/hcode-test-edit-keys")
      [{"id_rsa", "aaa"}, {"credentials", "x"}, {".env.production", "Y=1"}].each do |name, body|
        File.write("/tmp/hcode-test-edit-keys/#{name}", body)
        edit = Hcode::Tools::Edit.new("/tmp/hcode-test-edit-keys")
        result = edit.execute(JSON.parse(%({"path":"#{name}","old_string":"#{body}","new_string":"z"})))
        result.is_error?.should be_true
        result.content.should contain("sensitive-file pattern")
      end
    end

    it "allows editing .env.example (exemption)" do
      Dir.mkdir_p("/tmp/hcode-test-edit-exempt")
      File.write("/tmp/hcode-test-edit-exempt/.env.example", "foo\n")

      edit = Hcode::Tools::Edit.new("/tmp/hcode-test-edit-exempt")
      result = edit.execute(JSON.parse(%({"path":".env.example","old_string":"foo","new_string":"bar"})))
      result.is_error?.should be_false
      File.read("/tmp/hcode-test-edit-exempt/.env.example").should eq("bar\n")
    end

    it "rejects a relative path that escapes the workspace" do
      Dir.mkdir_p("/tmp/hcode-test-edit-ws")
      File.write("/tmp/escape-target.txt", "hello\n")

      edit = Hcode::Tools::Edit.new("/tmp/hcode-test-edit-ws")
      result = edit.execute(JSON.parse(%({"path":"../escape-target.txt","old_string":"hello","new_string":"bye"})))
      result.is_error?.should be_true
      result.content.should contain("not an absolute path")
      # Untouched
      File.read("/tmp/escape-target.txt").should eq("hello\n")
    end

    it "allows an absolute path outside the workspace" do
      Dir.mkdir_p("/tmp/hcode-test-edit-ws2")
      File.write("/tmp/hcode-test-edit-abs.txt", "hello\n")

      edit = Hcode::Tools::Edit.new("/tmp/hcode-test-edit-ws2")
      result = edit.execute(JSON.parse(%({"path":"/tmp/hcode-test-edit-abs.txt","old_string":"hello","new_string":"bye"})))
      result.is_error?.should be_false
      File.read("/tmp/hcode-test-edit-abs.txt").should eq("bye\n")
    end
  end
end
