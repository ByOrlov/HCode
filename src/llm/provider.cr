module Hcode
  module LLM
    # Abstract base for all chat-completion backends.
    #
    # A Provider converts the shared Message / ToolDefinition types into a
    # provider-specific request, streams the response back as MessagePart
    # deltas, and returns the aggregated StepResult. The agent loop depends
    # only on this abstraction, so a new backend can be added by subclassing
    # Provider and appending an entry to KNOWN_PROVIDERS.
    abstract class Provider
      # Short stable identifier for the backend ("moonshot", "openai", ...).
      # Surfaced by the /provider selector and the status footer.
      abstract def name : String

      # Upstream model name sent to the API (e.g. "kimi-for-coding").
      abstract def model_name : String

      # Fetch the list of model IDs available on this backend via
      # GET /models. Used by the /model selector at runtime.
      abstract def fetch_models : Array(String)

      # Send a conversation to the model and stream the response.
      #
      # Yields each streaming MessagePart (text deltas, tool-call deltas,
      # usage, finish reason) as they arrive, then returns the aggregated
      # StepResult. `aborted?` is polled so the provider can tear down an
      # in-flight connection when the user cancels.
      abstract def chat(messages : Array(Message), tools : Array(ToolDefinition)?,
                        system_prompt : String? = nil,
                        aborted? : -> Bool = -> { false },
                        &block : MessagePart ->) : StepResult

      # Runtime request-config hooks. The base Provider no-ops them so the
      # agent loop can call them uniformly on any backend; OpenAIChatProvider
      # overrides to fold them into the request body (prompt-cache key, thinking
      # effort, per-step completion-token budget clamp). Providers that do not
      # support a given field simply ignore it.
      def prompt_cache_key=(key : String?) : Nil
      end

      def thinking_effort=(effort : String?) : Nil
      end

      # Returns the current thinking-effort hint or nil. The base Provider
      # always returns nil (no concept of effort); OpenAIChatProvider
      # overrides to expose the configured value.
      def thinking_effort : String?
        nil
      end

      def max_context_tokens=(tokens : Int32?) : Nil
      end

      # Updated by the agent before each step so the provider can clamp the
      # completion budget against the remaining context window.
      def used_context_tokens=(tokens : Int32) : Nil
      end
    end

    # Metadata for a selectable backend, listed by the /provider command.
    struct ProviderInfo
      property name : String
      property description : String

      def initialize(@name : String, @description : String)
      end
    end

    DEFAULT_PROVIDER_NAME = nil

    # Known backends. Moonshot is the default; append entries here as new
    # Provider subclasses are implemented so the /provider selector can
    # enumerate them.
    KNOWN_PROVIDERS = [
      ProviderInfo.new("moonshot", "Moonshot — Chat Completions (default)"),
      ProviderInfo.new("zai", "Z.AI / Zhipu — pay-as-you-go (OpenAI-compatible)"),
      ProviderInfo.new("ollama", "Ollama — local models, no API key"),
      ProviderInfo.new("lmstudio", "LM Studio — local models, no API key"),
      ProviderInfo.new("mock", "Mock — scripted self-test provider (testing)"),
    ] of ProviderInfo

    def self.known_provider?(name : String) : Bool
      KNOWN_PROVIDERS.any? { |p| p.name == name }
    end
  end
end
