module Hcode
  module Setup
    class SetupRequired < Exception
      def initialize(message : String? = nil)
        super(message || Hcode.t("setup.required_message"))
      end
    end

    struct ProviderChoice
      property name : String
      property label : String
      property? needs_key : Bool
      property default_endpoint : String
      property default_model : String
      property key_hint : String

      def initialize(@name : String, @label : String, @needs_key : Bool,
                     @default_endpoint : String, @default_model : String,
                     @key_hint : String = "")
      end
    end

    PROVIDER_CHOICES = [
      ProviderChoice.new("moonshot", "Moonshot (Kimi)", true,
        "https://api.kimi.com/coding/v1", "kimi-for-coding",
        "Get a key at https://www.kimi.com/code/console"),
      ProviderChoice.new("ollama", "Local — Ollama", false,
        "http://localhost:11434/v1", "llama3.2"),
      ProviderChoice.new("lmstudio", "Local — LM Studio", false,
        "http://localhost:1234/v1", "local-model"),
      ProviderChoice.new("zai", "Z.AI / Zhipu (GLM)", true,
        "https://api.z.ai/api/paas/v4", "glm-4.6",
        "Get a key at https://z.ai"),
    ] of ProviderChoice

    # Stateful first-run wizard. Driven by the TUI input box: each step
    # produces a placeholder string; the user types a value and submits.
    # When the provider needs no key (ollama / lmstudio), the credentials
    # step is skipped entirely.
    class Wizard
      enum Step
        Welcome
        Credentials
        Endpoint
        Model
        Done
      end

      property step : Step = Step::Welcome
      property provider_name : String? = nil
      property api_key : String = ""
      property endpoint : String? = nil
      property model : String? = nil

      def self.choices : Array(ProviderChoice)
        PROVIDER_CHOICES
      end

      def current_choice : ProviderChoice?
        PROVIDER_CHOICES.find { |c| c.name == provider_name }
      end

      def done? : Bool
        step == Step::Done
      end

      # Placeholder text for the editor input box at the current step.
      def placeholder : String
        case step
        when Step::Welcome
          Hcode.t("setup.pick_provider")
        when Step::Credentials
          if hint = current_choice.try(&.key_hint).presence
            Hcode.t("setup.enter_api_key_hint", hint: hint)
          else
            Hcode.t("setup.enter_api_key")
          end
        when Step::Endpoint
          Hcode.t("setup.enter_endpoint", value: default_endpoint)
        when Step::Model
          Hcode.t("setup.enter_model", value: default_model)
        else
          ""
        end
      end

      private def default_endpoint : String
        current_choice.try(&.default_endpoint) || ""
      end

      private def default_model : String
        current_choice.try(&.default_model) || ""
      end

      # Called when the user submits a provider name (from the selector list).
      def select_provider(name : String) : Nil
        self.provider_name = name
        choice = current_choice
        if choice && !choice.needs_key?
          # Local providers skip credentials; endpoint and model get sensible
          # defaults so we can fast-forward unless the user wants to override.
          self.endpoint = choice.default_endpoint
          self.model = choice.default_model
          self.step = Step::Endpoint
        else
          self.step = Step::Credentials
        end
      end

      # Called when the user submits typed text (key / endpoint / model).
      # An empty submission keeps the default for endpoint/model.
      def submit_text(text : String) : Nil
        case step
        when Step::Credentials
          self.api_key = text
          self.step = Step::Endpoint
        when Step::Endpoint
          self.endpoint = text.empty? ? default_endpoint : text
          self.step = Step::Model
        when Step::Model
          self.model = text.empty? ? default_model : text
          self.step = Step::Done
        end
      end

      # Step the wizard one step backward. Clears any value collected on the
      # step being left so re-entering it starts clean.
      def back : Nil
        case step
        when Step::Credentials
          self.api_key = ""
          self.provider_name = nil
          self.step = Step::Welcome
        when Step::Endpoint
          self.endpoint = nil
          self.step = Step::Credentials
        when Step::Model
          self.model = nil
          self.step = Step::Endpoint
        end
      end

      # Write the collected values into a Config and persist it.
      def apply_to(config : Config::Config) : Nil
        config.provider_name = provider_name
        case provider_name
        when "moonshot"
          config.api_key = api_key
          config.endpoint = endpoint
          config.model = model
        when "ollama"
          config.ollama_endpoint = endpoint
          config.ollama_model = model
        when "lmstudio"
          config.lmstudio_endpoint = endpoint
          config.lmstudio_model = model
        when "zai"
          config.zai_api_key = api_key
          config.zai_endpoint = endpoint || ""
          config.zai_model = model || ""
        end
      end
    end
  end
end
