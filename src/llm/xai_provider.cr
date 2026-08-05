module Hcode
  module LLM
    # xAI (Grok) backend over the OpenAI Chat Completions protocol. Auth is a
    # plain API key — no OAuth. Grok supports the OpenAI-style top-level
    # `reasoning_effort` string for reasoning control, so `thinking_wire` is
    # `ReasoningEffort`. Shares the SSE transport through OpenAIChatProvider.
    class XaiProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "grok-4"
      DEFAULT_ENDPOINT = "https://api.x.ai/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
        # xAI is OpenAI-compatible: it speaks the top-level `reasoning_effort`
        # string for reasoning control. `off`/`on` have no wire encoding here.
        @thinking_wire = ThinkingWire::ReasoningEffort
      end

      def name : String
        "xai"
      end

      def token : String
        @api_key
      end
    end

    Provider.register("xai", "xAI (Grok) — OpenAI-compatible with reasoning",
      label: "xAI (Grok)",
      default_endpoint: XaiProvider::DEFAULT_ENDPOINT,
      default_model: XaiProvider::DEFAULT_MODEL,
      key_hint: "Get a key at https://console.x.ai") do |config, _|
      if config.xai_api_key.empty?
        raise ProviderConfigError.new(
          "No xAI credentials found. Set the XAI_API_KEY environment variable " \
          "(or [provider.xai] api_key in config).")
      end
      XaiProvider.new(
        model: config.xai_model,
        endpoint: config.xai_endpoint,
        api_key: config.xai_api_key,
      )
    end
  end
end
