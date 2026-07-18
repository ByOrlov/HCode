require "../spec_helper"

describe Kimi::Tools::PathAccess do
  describe ".canonicalize" do
    it "resolves a relative path against cwd" do
      Kimi::Tools::PathAccess.canonicalize("foo/bar", "/work").should eq("/work/foo/bar")
    end

    it "normalizes .. and . segments lexically" do
      Kimi::Tools::PathAccess.canonicalize("foo/../bar", "/work").should eq("/work/bar")
      Kimi::Tools::PathAccess.canonicalize("foo/./bar", "/work").should eq("/work/foo/bar")
      Kimi::Tools::PathAccess.canonicalize("/work/foo/../bar", "/other").should eq("/work/bar")
    end

    it "rejects empty paths" do
      err = expect_raises(Kimi::Tools::PathAccess::AccessError, "Path cannot be empty") do
        Kimi::Tools::PathAccess.canonicalize("", "/work")
      end
      err.code.should eq("PATH_INVALID")
    end

    it "does not let a sibling prefix fake workspace membership" do
      c = Kimi::Tools::PathAccess.canonicalize("/workspace-evil/x", "/workspace")
      c.should eq("/workspace-evil/x")
      Kimi::Tools::PathAccess.within_directory?(c, "/workspace").should be_false
    end
  end

  describe ".within_directory?" do
    it "accepts the base itself" do
      Kimi::Tools::PathAccess.within_directory?("/work", "/work").should be_true
      Kimi::Tools::PathAccess.within_directory?("/work/", "/work").should be_true
    end

    it "accepts a descendant" do
      Kimi::Tools::PathAccess.within_directory?("/work/foo/bar", "/work").should be_true
    end

    it "rejects a sibling-prefix path" do
      Kimi::Tools::PathAccess.within_directory?("/workspace-evil", "/workspace").should be_false
      Kimi::Tools::PathAccess.within_directory?("/work-other", "/work").should be_false
    end
  end

  describe ".resolve" do
    it "returns the canonical path for an inside-workspace relative file" do
      Kimi::Tools::PathAccess.resolve("src/main.cr", "/work", Kimi::Tools::PathAccess::Mode::Write)
        .should eq("/work/src/main.cr")
    end

    it "returns the canonical path for an outside-workspace absolute file" do
      Kimi::Tools::PathAccess.resolve("/etc/hosts", "/work", Kimi::Tools::PathAccess::Mode::Read)
        .should eq("/etc/hosts")
    end

    it "raises PATH_SENSITIVE for a blocked file (delegates to Sensitive)" do
      err = expect_raises(Kimi::Tools::PathAccess::AccessError, /sensitive-file pattern/) do
        Kimi::Tools::PathAccess.resolve(".env", "/work", Kimi::Tools::PathAccess::Mode::Read)
      end
      err.code.should eq("PATH_SENSITIVE")
      err.raw_path.should eq(".env")
      err.canonical_path.should eq("/work/.env")
    end

    it "raises PATH_SENSITIVE for SSH keys and credentials" do
      ["id_rsa", "id_ed25519", "credentials", ".env.production"].each do |name|
        err = expect_raises(Kimi::Tools::PathAccess::AccessError, /sensitive-file pattern/) do
          Kimi::Tools::PathAccess.resolve(name, "/work", Kimi::Tools::PathAccess::Mode::Read)
        end
        err.code.should eq("PATH_SENSITIVE")
      end
    end

    it "raises PATH_OUTSIDE_WORKSPACE for a relative path that escapes" do
      err = expect_raises(Kimi::Tools::PathAccess::AccessError, /not an absolute path/) do
        Kimi::Tools::PathAccess.resolve("../secret.txt", "/work", Kimi::Tools::PathAccess::Mode::Read)
      end
      err.code.should eq("PATH_OUTSIDE_WORKSPACE")
      err.raw_path.should eq("../secret.txt")
      err.canonical_path.should eq("/secret.txt")
    end

    it "allows an outside-workspace path when explicitly absolute" do
      Kimi::Tools::PathAccess.resolve("/etc/hosts", "/work", Kimi::Tools::PathAccess::Mode::Write)
        .should eq("/etc/hosts")
    end

    it "skips the sensitive check when check_sensitive is false" do
      Kimi::Tools::PathAccess.resolve(".env", "/work", Kimi::Tools::PathAccess::Mode::Read,
        check_sensitive: false).should eq("/work/.env")
    end

    it "words the error per mode" do
      write_err = expect_raises(Kimi::Tools::PathAccess::AccessError, /write or edit a file/) do
        Kimi::Tools::PathAccess.resolve("../s", "/work", Kimi::Tools::PathAccess::Mode::Write)
      end
      search_err = expect_raises(Kimi::Tools::PathAccess::AccessError, /search/) do
        Kimi::Tools::PathAccess.resolve("../s", "/work", Kimi::Tools::PathAccess::Mode::Search)
      end
      read_err = expect_raises(Kimi::Tools::PathAccess::AccessError, /read a file/) do
        Kimi::Tools::PathAccess.resolve("../s", "/work", Kimi::Tools::PathAccess::Mode::Read)
      end
      {write_err, search_err, read_err}.each { |e| e.code.should eq("PATH_OUTSIDE_WORKSPACE") }
    end

    it "defaults mode to Write" do
      # Same message wording as an explicit Mode::Write — confirms default.
      err = expect_raises(Kimi::Tools::PathAccess::AccessError, /write or edit a file/) do
        Kimi::Tools::PathAccess.resolve("../s", "/work")
      end
      err.code.should eq("PATH_OUTSIDE_WORKSPACE")
    end
  end
end
