module H2code
  module LLM
    # OpenRouter backend over the OpenAI Chat Completions protocol. Auth is a
    # plain API key — no OAuth. Shares the SSE transport through
    # OpenAIChatProvider. OpenRouter aggregates many providers behind one key.
    class OpenrouterProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "anthropic/claude-3.5-sonnet"
      DEFAULT_ENDPOINT = "https://openrouter.ai/api/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "openrouter"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("openrouter", "OpenRouter — multi-model gateway (OpenAI-compatible)",
      label: "OpenRouter",
      default_endpoint: OpenrouterProvider::DEFAULT_ENDPOINT,
      default_model: OpenrouterProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://openrouter.ai/keys") do |config, _|
      if config.openrouter_api_key.empty?
        raise ProviderConfigError.new(
          "No OpenRouter credentials found. Set the OPENROUTER_API_KEY environment variable " \
          "(or [provider.openrouter] api_key in config).")
      end
      OpenrouterProvider.new(
        model: config.openrouter_model,
        endpoint: config.openrouter_endpoint,
        api_key: config.openrouter_api_key,
      )
    end
  end
end
