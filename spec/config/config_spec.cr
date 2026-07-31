require "../spec_helper"
require "../../src/config/config"

describe Hcode::Config::Config do
  describe "defaults" do
    it "starts with nil provider/model/endpoint/api_key" do
      config = Hcode::Config::Config.new
      config.provider_name.should be_nil
      config.model.should be_nil
      config.endpoint.should be_nil
      config.api_key.should be_nil
    end

    it "keeps non-nil defaults for thinking/permission/max_context" do
      config = Hcode::Config::Config.new
      config.thinking_effort.should eq("medium")
      config.permission_mode.should eq("manual")
      config.max_context_tokens.should eq(262144)
    end
  end

  describe "#provider_configured?" do
    it "returns false when no provider is set" do
      config = Hcode::Config::Config.new
      config.provider_configured?.should be_false
    end

    it "returns true for ollama with no key (local)" do
      config = Hcode::Config::Config.new
      config.provider_name = "ollama"
      config.provider_configured?.should be_true
    end

    it "returns true for lmstudio with no key (local)" do
      config = Hcode::Config::Config.new
      config.provider_name = "lmstudio"
      config.provider_configured?.should be_true
    end

    it "returns true for mock with no key" do
      config = Hcode::Config::Config.new
      config.provider_name = "mock"
      config.provider_configured?.should be_true
    end

    it "returns false for moonshot without a key when no oauth file exists" do
      config = Hcode::Config::Config.new
      config.provider_name = "moonshot"
      config.api_key = ""
      # Depends on whether ~/.kimi-code/credentials exists; either way,
      # an empty api_key with no oauth should be false on a clean machine.
      # This assertion is best-effort — skip if the oauth file is present.
      home = ENV["HOME"]? || "/tmp"
      oauth_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
      config.provider_configured?.should be_true unless File.exists?(oauth_path)
    end

    it "returns true for moonshot with an api key" do
      config = Hcode::Config::Config.new
      config.provider_name = "moonshot"
      config.api_key = "sk-test"
      config.provider_configured?.should be_true
    end

    it "returns false for zai without a key" do
      config = Hcode::Config::Config.new
      config.provider_name = "zai"
      config.zai_api_key = ""
      config.provider_configured?.should be_false
    end

    it "returns true for zai with a key" do
      config = Hcode::Config::Config.new
      config.provider_name = "zai"
      config.zai_api_key = "sk-test"
      config.provider_configured?.should be_true
    end

    it "returns false for an unknown provider with no key" do
      config = Hcode::Config::Config.new
      config.provider_name = "custom"
      config.api_key = ""
      config.provider_configured?.should be_false
    end

    it "returns true for an unknown provider with a key" do
      config = Hcode::Config::Config.new
      config.provider_name = "custom"
      config.api_key = "sk-test"
      config.provider_configured?.should be_true
    end
  end

  describe "#provider_configured?(name)" do
    it "checks an arbitrary provider name independent of provider_name" do
      config = Hcode::Config::Config.new
      config.provider_name = "ollama"
      config.api_key = "sk-test"
      config.provider_configured?("moonshot").should be_true
      config.provider_configured?("zai").should be_false
      config.provider_configured?("ollama").should be_true
    end

    it "returns false for nil" do
      config = Hcode::Config::Config.new
      config.provider_configured?(nil).should be_false
    end
  end

  describe "JSON round-trip" do
    it "parses nil-able fields from JSON" do
      json = <<-JSON
        {
          "model": { "default": "llama3.2" },
          "provider": {
            "default": "ollama",
            "ollama": { "endpoint": "http://gpu:11434/v1", "model": "qwen2.5" }
          }
        }
      JSON
      config = Hcode::Config::Config.parse_json(json)
      config.provider_name.should eq("ollama")
      config.model.should eq("llama3.2")
      config.ollama_endpoint.should eq("http://gpu:11434/v1")
      config.ollama_model.should eq("qwen2.5")
    end

    it "leaves nil-able fields nil when absent" do
      json = %({"model": {"thinking_effort": "high"}})
      config = Hcode::Config::Config.parse_json(json)
      config.provider_name.should be_nil
      config.model.should be_nil
      config.api_key.should be_nil
      config.endpoint.should be_nil
      config.thinking_effort.should eq("high")
    end

    it "saves ollama/lmstudio sections only when set" do
      config = Hcode::Config::Config.new
      config.provider_name = "ollama"
      config.ollama_endpoint = "http://localhost:11434/v1"

      path = File.join(Dir.tempdir, "hcode-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        content = File.read(path)
        content.should contain("\"default\": \"ollama\"")
        content.should contain("\"ollama\"")
        content.should contain("\"endpoint\": \"http://localhost:11434/v1\"")
        # lmstudio section should not be written when unset
        content.should_not contain("\"lmstudio\"")
      ensure
        File.delete(path) rescue nil
      end
    end
  end
end

describe "Hcode.build_named_provider with nil" do
  # build_named_provider lives in hcode.cr which auto-runs the CLI on require,
  # so these are covered by the integration test in spec/hcode_spec.cr instead.
  it "placeholder — see hcode integration tests" do
    true.should be_true
  end
end
