require "spec"
require "file_utils"
require "../src/version"
require "../src/version_compare"
require "../src/i18n/i18n"
require "../src/upgrader"

Hcode::I18n.init("en")

describe Hcode::Upgrader do
  describe ".asset_name" do
    it "returns a non-empty asset name matching the platform pattern" do
      name = Hcode::Upgrader.asset_name
      name.should match(/^hcode-(x86_64|aarch64)-(linux|darwin|windows)\.(tar\.gz|zip)$/)
    end
  end

  describe ".current_version" do
    it "returns the compile-time VERSION constant" do
      Hcode::Upgrader.current_version.should eq(Hcode::VERSION)
    end
  end

  describe ".run" do
    original = Hcode::Upgrader.http_get

    after_each do
      Hcode::Upgrader.http_get = original
    end

    it "reports up-to-date when latest equals current" do
      Hcode::Upgrader.http_get = ->(url : String) {
        if url.includes?("/releases/latest")
          %({"tag_name": "#{Hcode::VERSION}"})
        else
          ""
        end
      }
      ok, msg = Hcode::Upgrader.run
      ok.should be_true
      msg.should contain(Hcode::VERSION)
    end

    it "reports failure when GitHub API is unreachable" do
      Hcode::Upgrader.http_get = ->(url : String) {
        raise "network error"
      }
      ok, msg = Hcode::Upgrader.run
      ok.should be_false
      msg.should_not be_empty
    end
  end

  describe ".latest_version" do
    it "parses tag_name from the GitHub releases JSON" do
      Hcode::Upgrader.http_get = ->(url : String) {
        %({"tag_name": "2026.07.31.3", "name": "2026.07.31.3"})
      }
      Hcode::Upgrader.latest_version.should eq("2026.07.31.3")
    end

    it "returns nil on malformed JSON" do
      Hcode::Upgrader.http_get = ->(url : String) { "not json" }
      Hcode::Upgrader.latest_version.should be_nil
    end
  end

  describe "update-check cache" do
    original_http = Hcode::Upgrader.http_get
    original_now = Hcode::Upgrader.now
    original_cache = Hcode::Upgrader.cache_path
    tmp_dir = File.join(Dir.tempdir, "hcode-spec-#{Random::Secure.hex(4)}")

    after_each do
      Hcode::Upgrader.http_get = original_http
      Hcode::Upgrader.now = original_now
      Hcode::Upgrader.cache_path = original_cache
      FileUtils.rm_rf(tmp_dir) if Dir.exists?(tmp_dir)
    end

    it "should_check? returns true when no cache file exists" do
      Hcode::Upgrader.cache_path = ->{ File.join(tmp_dir, "missing.json") }
      Hcode::Upgrader.should_check?.should be_true
    end

    it "should_check? returns false within 24 hours" do
      path = File.join(tmp_dir, "recent.json")
      Dir.mkdir_p(tmp_dir)
      recent = (Time.utc - 1.hour).to_rfc3339
      File.write(path, %({"checked_at": "#{recent}", "latest": "1.0.0"}))
      Hcode::Upgrader.cache_path = ->{ path }
      Hcode::Upgrader.should_check?.should be_false
    end

    it "should_check? returns true after 24 hours" do
      path = File.join(tmp_dir, "stale.json")
      Dir.mkdir_p(tmp_dir)
      stale = (Time.utc - 25.hours).to_rfc3339
      File.write(path, %({"checked_at": "#{stale}", "latest": "1.0.0"}))
      Hcode::Upgrader.cache_path = ->{ path }
      Hcode::Upgrader.should_check?.should be_true
    end

    it "record_check writes a valid timestamp to the cache file" do
      path = File.join(tmp_dir, "written.json")
      Dir.mkdir_p(tmp_dir)
      fixed_time = Time.utc(2026, 1, 15, 12, 0, 0)
      Hcode::Upgrader.cache_path = ->{ path }
      Hcode::Upgrader.now = ->{ fixed_time }
      Hcode::Upgrader.record_check("9.9.9")
      File.exists?(path).should be_true
      json = JSON.parse(File.read(path))
      json["checked_at"].as_s.should eq(fixed_time.to_rfc3339)
      json["latest"].as_s.should eq("9.9.9")
    end

    it "background_check returns nil and skips network when cache is fresh" do
      path = File.join(tmp_dir, "fresh_bg.json")
      Dir.mkdir_p(tmp_dir)
      recent = (Time.utc - 1.hour).to_rfc3339
      File.write(path, %({"checked_at": "#{recent}", "latest": "1.0.0"}))
      Hcode::Upgrader.cache_path = ->{ path }
      network_called = false
      Hcode::Upgrader.http_get = ->(url : String) { network_called = true; "" }
      Hcode::Upgrader.background_check.should be_nil
      network_called.should be_false
    end

    it "background_check returns notification when newer version available" do
      path = File.join(tmp_dir, "notify.json")
      Dir.mkdir_p(tmp_dir)
      Hcode::Upgrader.cache_path = ->{ path }
      Hcode::Upgrader.http_get = ->(url : String) {
        %({"tag_name": "9999.99.99.99"})
      }
      result = Hcode::Upgrader.background_check
      result.should_not be_nil
      result.not_nil!.should contain("9999.99.99.99")
      # Cache file should have been written.
      File.exists?(path).should be_true
    end

    it "background_check returns nil when already up-to-date" do
      path = File.join(tmp_dir, "uptodate.json")
      Dir.mkdir_p(tmp_dir)
      Hcode::Upgrader.cache_path = ->{ path }
      Hcode::Upgrader.http_get = ->(url : String) {
        %({"tag_name": "#{Hcode::VERSION}"})
      }
      Hcode::Upgrader.background_check.should be_nil
    end
  end
end
