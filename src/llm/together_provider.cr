module Hcode
  module LLM
    # Together backend over the OpenAI Chat Completions protocol. Auth is a
    # plain API key — no OAuth. Shares the SSE transport through
    # OpenAIChatProvider.
    class TogetherProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "meta-llama/Llama-3.3-70B-Instruct-Turbo"
      DEFAULT_ENDPOINT = "https://api.together.xyz/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "together"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("together", "Together — OpenAI-compatible",
      label: "Together",
      default_endpoint: TogetherProvider::DEFAULT_ENDPOINT,
      default_model: TogetherProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://api.together.ai/settings/api-keys") do |config, _|
      if config.together_api_key.empty?
        raise ProviderConfigError.new(
          "No Together credentials found. Set the TOGETHER_API_KEY environment variable " \
          "(or [provider.together] api_key in config).")
      end
      TogetherProvider.new(
        model: config.together_model,
        endpoint: config.together_endpoint,
        api_key: config.together_api_key,
      )
    end
  end
end
