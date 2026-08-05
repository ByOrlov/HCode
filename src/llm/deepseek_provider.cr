module Hcode
  module LLM
    # DeepSeek backend over the OpenAI Chat Completions protocol. Auth is a
    # plain API key — no OAuth. Shares the SSE transport with the other
    # OpenAI-compatible backends through OpenAIChatProvider.
    class DeepseekProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "deepseek-chat"
      DEFAULT_ENDPOINT = "https://api.deepseek.com/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "deepseek"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("deepseek", "DeepSeek — OpenAI-compatible",
      label: "DeepSeek",
      default_endpoint: DeepseekProvider::DEFAULT_ENDPOINT,
      default_model: DeepseekProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://platform.deepseek.com") do |config, _|
      if config.deepseek_api_key.empty?
        raise ProviderConfigError.new(
          "No DeepSeek credentials found. Set the DEEPSEEK_API_KEY environment variable " \
          "(or [provider.deepseek] api_key in config).")
      end
      DeepseekProvider.new(
        model: config.deepseek_model,
        endpoint: config.deepseek_endpoint,
        api_key: config.deepseek_api_key,
      )
    end
  end
end
