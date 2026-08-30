require "../spec_helper"
require "../../src/setup/wizard"
require "../../src/config/config"

describe H2code::Setup::Wizard do
  describe "provider choices" do
    it "includes moonshot, ollama, lmstudio, zai" do
      names = H2code::Setup::Wizard.choices.map(&.name)
      names.should contain("moonshot")
      names.should contain("ollama")
      names.should contain("lmstudio")
      names.should contain("zai")
    end

    it "marks local providers as not needing a key" do
      ollama = H2code::Setup::Wizard.choices.find! { |c| c.name == "ollama" }
      ollama.needs_key?.should be_false
      lmstudio = H2code::Setup::Wizard.choices.find! { |c| c.name == "lmstudio" }
      lmstudio.needs_key?.should be_false
    end

    it "marks cloud providers as needing a key" do
      moonshot = H2code::Setup::Wizard.choices.find! { |c| c.name == "moonshot" }
      moonshot.needs_key?.should be_true
    end

    it "excludes hidden providers (mock) from the wizard" do
      names = H2code::Setup::Wizard.choices.map(&.name)
      names.should_not contain("mock")
    end

    it "includes all seven new OpenAI-compatible cloud providers" do
      names = H2code::Setup::Wizard.choices.map(&.name)
      %w[deepseek groq openrouter xai cerebras fireworks together].each do |name|
        names.should contain(name)
      end
    end
  end

  describe "state machine — keyless provider (ollama)" do
    it "skips credentials and fast-forwards to endpoint" do
      wizard = H2code::Setup::Wizard.new
      wizard.step.should eq(H2code::Setup::Wizard::Step::Welcome)

      wizard.select_provider("ollama")
      wizard.provider_name.should eq("ollama")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)
    end

    it "accepts default endpoint with empty submit" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("ollama")
      wizard.submit_text("")
      wizard.endpoint.should eq("http://localhost:11434/v1")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Model)
    end

    it "accepts default model with empty submit and completes" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("ollama")
      wizard.submit_text("") # endpoint
      wizard.submit_text("") # model
      wizard.model.should eq("llama3.2")
      wizard.done?.should be_true
    end

    it "honours overridden endpoint and model" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("ollama")
      wizard.submit_text("http://gpu:11434/v1")
      wizard.submit_text("qwen2.5")
      wizard.endpoint.should eq("http://gpu:11434/v1")
      wizard.model.should eq("qwen2.5")
      wizard.done?.should be_true
    end
  end

  describe "state machine — keyed provider (moonshot)" do
    it "goes through credentials → endpoint → model" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("moonshot")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Credentials)

      wizard.submit_text("sk-test-123")
      wizard.api_key.should eq("sk-test-123")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)

      wizard.submit_text("")
      wizard.endpoint.should eq("https://api.kimi.com/coding/v1")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Model)

      wizard.submit_text("")
      wizard.model.should eq("kimi-for-coding")
      wizard.done?.should be_true
    end
  end

  describe "#placeholder" do
    it "shows a provider-picker hint at welcome" do
      wizard = H2code::Setup::Wizard.new
      wizard.placeholder.should contain("provider")
    end

    it "shows the API key prompt at credentials" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("moonshot")
      wizard.placeholder.should contain("API key")
    end

    it "includes the default endpoint in the endpoint placeholder" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("ollama")
      wizard.placeholder.should contain("http://localhost:11434/v1")
    end

    it "includes the default model in the model placeholder" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("ollama")
      wizard.submit_text("")
      wizard.placeholder.should contain("llama3.2")
    end
  end

  describe "#back" do
    it "steps credentials back to welcome and clears the api key" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("moonshot")
      wizard.submit_text("sk-test")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)
      wizard.back # Endpoint → Credentials, clears endpoint
      wizard.step.should eq(H2code::Setup::Wizard::Step::Credentials)
      wizard.back # Credentials → Welcome, clears api_key + provider_name
      wizard.step.should eq(H2code::Setup::Wizard::Step::Welcome)
      wizard.api_key.should eq("")
      wizard.provider_name.should be_nil
    end

    it "steps model back to endpoint and clears the model" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("moonshot")
      wizard.submit_text("sk-test")
      wizard.submit_text("")
      wizard.step.should eq(H2code::Setup::Wizard::Step::Model)
      wizard.back # Model → Endpoint, clears model
      wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)
      wizard.model.should be_nil
    end

    it "is a no-op on welcome" do
      wizard = H2code::Setup::Wizard.new
      wizard.back
      wizard.step.should eq(H2code::Setup::Wizard::Step::Welcome)
    end
  end

  describe "#apply_to" do
    it "writes ollama config fields" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("ollama")
      wizard.submit_text("http://gpu:11434/v1")
      wizard.submit_text("qwen2.5")

      config = H2code::Config::Config.new
      wizard.apply_to(config)
      config.provider_name.should eq("ollama")
      config.ollama_endpoint.should eq("http://gpu:11434/v1")
      config.ollama_model.should eq("qwen2.5")
    end

    it "writes moonshot config fields" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("moonshot")
      wizard.submit_text("sk-test")
      wizard.submit_text("")
      wizard.submit_text("")

      config = H2code::Config::Config.new
      wizard.apply_to(config)
      config.provider_name.should eq("moonshot")
      config.api_key.should eq("sk-test")
      config.endpoint.should eq("https://api.kimi.com/coding/v1")
      config.model.should eq("kimi-for-coding")
    end

    it "writes lmstudio config fields" do
      wizard = H2code::Setup::Wizard.new
      wizard.select_provider("lmstudio")
      wizard.submit_text("")
      wizard.submit_text("")

      config = H2code::Config::Config.new
      wizard.apply_to(config)
      config.provider_name.should eq("lmstudio")
      config.lmstudio_endpoint.should eq("http://localhost:1234/v1")
    end
  end
end
