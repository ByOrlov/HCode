require "spec"
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
end
