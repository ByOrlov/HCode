module H2code
  module LLM
    # Cerebras backend over the OpenAI Chat Completions protocol. Auth is a
    # plain API key — no OAuth. Shares the SSE transport through
    # OpenAIChatProvider. Cerebras offers fast inference.
    class CerebrasProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "llama-3.3-70b"
      DEFAULT_ENDPOINT = "https://api.cerebras.ai/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "cerebras"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("cerebras", "Cerebras — OpenAI-compatible (fast inference)",
      label: "Cerebras",
      default_endpoint: CerebrasProvider::DEFAULT_ENDPOINT,
      default_model: CerebrasProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://cloud.cerebras.ai") do |config, _|
      if config.cerebras_api_key.empty?
        raise ProviderConfigError.new(
          "No Cerebras credentials found. Set the CEREBRAS_API_KEY environment variable " \
          "(or [provider.cerebras] api_key in config).")
      end
      CerebrasProvider.new(
        model: config.cerebras_model,
        endpoint: config.cerebras_endpoint,
        api_key: config.cerebras_api_key,
      )
    end
  end
end
