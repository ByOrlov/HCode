module Hcode
  module LLM
    # Fireworks backend over the OpenAI Chat Completions protocol. Auth is a
    # plain API key — no OAuth. Shares the SSE transport through
    # OpenAIChatProvider.
    class FireworksProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "accounts/fireworks/models/llama-v3p1-70b-instruct"
      DEFAULT_ENDPOINT = "https://api.fireworks.ai/inference/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "fireworks"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("fireworks", "Fireworks — OpenAI-compatible",
      label: "Fireworks",
      default_endpoint: FireworksProvider::DEFAULT_ENDPOINT,
      default_model: FireworksProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://fireworks.ai/account/api-keys") do |config, _|
      if config.fireworks_api_key.empty?
        raise ProviderConfigError.new(
          "No Fireworks credentials found. Set the FIREWORKS_API_KEY environment variable " \
          "(or [provider.fireworks] api_key in config).")
      end
      FireworksProvider.new(
        model: config.fireworks_model,
        endpoint: config.fireworks_endpoint,
        api_key: config.fireworks_api_key,
      )
    end
  end
end
