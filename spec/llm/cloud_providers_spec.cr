require "../spec_helper"

# The seven new OpenAI-compatible cloud providers are thin subclasses of
# OpenAIChatProvider. Their streaming/tool-call/abort behavior is identical to
# the base and already covered by openai_chat_provider_spec; here we verify the
# new surface: registry presence, naming, and config wiring
# (`provider_configured?`).

describe "OpenAI-compatible cloud providers" do
  names = ["cerebras", "deepseek", "fireworks", "groq", "openrouter", "together", "xai"]

  it "registers each provider in the Provider registry" do
    registered = H2code::LLM::Provider.providers.map(&.name)
    names.each { |name| registered.should contain(name) }
  end

  it "knows each provider name" do
    names.each { |name| H2code::LLM::Provider.known_provider?(name).should be_true }
  end

  it "marks provider unconfigured when its API key is absent" do
    names.each do |name|
      config = H2code::Config::Config.new
      config.provider_configured?(name).should be_false
    end
  end
end

# Per-provider config + construction checks. Each provider must build from a
# Config with its key set and reject an empty key with ProviderConfigError.
{% for provider in %w[deepseek groq openrouter xai cerebras fireworks together] %}
  describe {{ "H2code::LLM #{provider.camelcase} provider config" }} do
    it "is configured when the API key is set" do
      config = H2code::Config::Config.new
      config.provider_configured?({{ provider }}).should be_false
      config.{{ "#{provider.id}_api_key".id }} = "sk-test"
      config.provider_configured?({{ provider }}).should be_true
    end

    it "raises ProviderConfigError when built without a key" do
      config = H2code::Config::Config.new
      reg = H2code::LLM::Provider.find({{ provider }}).not_nil!
      expect_raises(H2code::LLM::ProviderConfigError) do
        reg.builder.call(config, nil)
      end
    end

    it "builds successfully when the key is set" do
      config = H2code::Config::Config.new
      config.{{ "#{provider.id}_api_key".id }} = "sk-test"
      reg = H2code::LLM::Provider.find({{ provider }}).not_nil!
      provider = reg.builder.call(config, nil).as(H2code::LLM::OpenAIChatProvider)
      provider.name.should eq({{ provider }})
      provider.token.should eq("sk-test")
    end
  end
{% end %}
