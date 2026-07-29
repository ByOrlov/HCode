module Hcode
  module LLM
    # Ollama backend over the OpenAI Chat Completions protocol. Ollama runs
    # locally and needs no API key — the `token` is always empty and the
    # `Authorization` header is omitted on the wire by `OpenAIChatProvider`.
    # Ollama has no reasoning-effort control, so `thinking_wire` stays `None`.
    class OllamaProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "llama3.2"
      DEFAULT_ENDPOINT = "http://localhost:11434/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
      end

      def name : String
        "ollama"
      end

      def token : String
        ""
      end
    end
  end
end
