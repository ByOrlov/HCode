module Hcode
  module LLM
    # Groq backend over the OpenAI Chat Completions protocol. Auth is a plain
    # API key — no OAuth. Shares the SSE transport through OpenAIChatProvider.
    class GroqProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "llama-3.3-70b-versatile"
      DEFAULT_ENDPOINT = "https://api.groq.com/openai/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "groq"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("groq", "Groq — OpenAI-compatible (fast inference)",
      label: "Groq",
      default_endpoint: GroqProvider::DEFAULT_ENDPOINT,
      default_model: GroqProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://console.groq.com/keys") do |config, _|
      if config.groq_api_key.empty?
        raise ProviderConfigError.new(
          "No Groq credentials found. Set the GROQ_API_KEY environment variable " \
          "(or [provider.groq] api_key in config).")
      end
      GroqProvider.new(
        model: config.groq_model,
        endpoint: config.groq_endpoint,
        api_key: config.groq_api_key,
      )
    end
  end
end
