module Kimi
  module LLM
    # Z.AI / Zhipu backend (GLM Coding Plan) over the OpenAI Chat Completions
    # protocol. Auth is a plain API key — no OAuth. Shares the SSE transport
    # with KimiProvider through OpenAIChatProvider.
    class ZaiProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "glm-4.6"
      DEFAULT_ENDPOINT = "https://api.z.ai/api/paas/v4"

      property provider_label : String

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     @provider_label : String = "zai",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
        # Z.AI / Zhipu (GLM) is OpenAI-compatible: it speaks the top-level
        # `reasoning_effort` string for reasoning control, not the Moonshot
        # `thinking` object. `off`/`on` have no wire encoding here.
        @thinking_wire = ThinkingWire::ReasoningEffort
      end

      def name : String
        @provider_label
      end

      def token : String
        @api_key
      end
    end
  end
end
