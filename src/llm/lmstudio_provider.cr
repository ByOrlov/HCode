module H2code
  module LLM
    # LM Studio backend over the OpenAI Chat Completions protocol. LM Studio
    # runs locally and needs no API key — the `token` is always empty and the
    # `Authorization` header is omitted on the wire by `OpenAIChatProvider`.
    # LM Studio has no reasoning-effort control, so `thinking_wire` stays `None`.
    class LmStudioProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "local-model"
      DEFAULT_ENDPOINT = "http://localhost:1234/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
        # Local model loading can take minutes before the first token — a
        # remote-provider-sized stall timeout would cancel legitimate work.
        @stream_stall_timeout = 5.minutes
      end

      def name : String
        "lmstudio"
      end

      def token : String
        ""
      end
    end

    Provider.register("lmstudio", "LM Studio — local models, no API key",
      label: "Local — LM Studio", needs_key: false,
      default_endpoint: "http://localhost:1234/v1",
      default_model: "local-model") do |config, _|
      endpoint = config.lmstudio_endpoint || LmStudioProvider::DEFAULT_ENDPOINT
      LmStudioProvider.new(
        model: config.lmstudio_model || LmStudioProvider::DEFAULT_MODEL,
        endpoint: endpoint,
      )
    end
  end
end
