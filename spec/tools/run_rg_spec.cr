require "../spec_helper"

def make_fake_rg(dir : String) : String
  path = File.join(dir, "rg")
  File.write(path, "#!/bin/sh\necho fake-rg\n")
  File.chmod(path, 0o755)
  path
end

describe H2code::Tools::RunRg do
  # Shared test directory — created once, cleaned up at the end.
  test_dir = "/tmp/h2code-test-run-rg"
  FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
  Dir.mkdir_p(test_dir)

  after_all do
    FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
  end

  describe ".resolve_rg_binary" do
    it "prefers rg from PATH entries" do
      bin_dir = File.join(test_dir, "bin")
      Dir.mkdir_p(bin_dir)
      fake = make_fake_rg(bin_dir)

      H2code::Tools::RunRg.resolve_rg_binary(bin_dir, [] of String).should eq(fake)
    end

    it "falls back to hardcoded locations when PATH has no rg" do
      empty_dir = File.join(test_dir, "empty")
      Dir.mkdir_p(empty_dir)
      fallback_dir = File.join(test_dir, "fallback")
      Dir.mkdir_p(fallback_dir)
      fake = make_fake_rg(fallback_dir)


      H2code::Tools::RunRg.resolve_rg_binary(empty_dir, [File.join(fallback_dir, "rg")])
        .should eq(fake)
    end

    it "returns plain rg when nothing is found" do
      empty_dir = File.join(test_dir, "empty")

      H2code::Tools::RunRg.resolve_rg_binary(empty_dir, [] of String).should eq("rg")
    end

    it "skips non-executable and non-file candidates" do
      empty_dir = File.join(test_dir, "empty")
      junk_dir = File.join(test_dir, "junk")
      Dir.mkdir_p(junk_dir)
      # A directory named "rg" — executable bit set, but not a file.
      Dir.mkdir(File.join(junk_dir, "rg"))


      H2code::Tools::RunRg.resolve_rg_binary(empty_dir, [File.join(junk_dir, "rg")]).should eq("rg")
    end

    it "expands ~ in fallback paths" do
      home_bin = File.join(ENV["HOME"], ".h2code-spec-rg-home")
      FileUtils.rm_rf(home_bin)
      Dir.mkdir_p(home_bin)
      fake = make_fake_rg(home_bin)


      tilde_path = "~/.h2code-spec-rg-home/rg"
      H2code::Tools::RunRg.resolve_rg_binary(nil, [tilde_path]).should eq(fake)
    ensure
      FileUtils.rm_rf(home_bin) if home_bin
    end
  end
end
