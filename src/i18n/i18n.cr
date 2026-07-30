require "i18n"

# Embed locale YAML files at compile time. The `embed` macro runs a
# compiler-time helper that reads every `.yml` under `locales/` and bakes
# the translations into the binary as a preloaded hash. Must live at the
# top level (outside `Hcode::I18n`) because the macro expands to
# `I18n::Loader::YAML.new(...)` and would otherwise resolve `I18n` to
# `Hcode::I18n`. The path must be a string literal (computed at compile
# time via a macro), not a runtime `File.join` call.
HCODE_EMBEDDED_I18N_LOADER = ::I18n::Loader::YAML.embed({{ __DIR__ + "/locales" }})

module Hcode
  # `I18n` domain — interface translation layer.
  #
  # Wraps the `crystal-i18n` shard: locale YAML files are embedded into the
  # binary at compile time (so there are no external files to ship), the
  # active locale is selected from config / env / system at startup, and the
  # `#t` shortcut is exposed app-wide as `Hcode.t(...)`.
  module I18n
    SUPPORTED_LOCALES = {"en", "ru", "es", "zh", "ja", "pt", "hi", "fa", "uk", "be"}

    @@initialized = false

    # Initializes the I18n module with the embedded locale files and activates
    # the given locale. Safe to call once; subsequent calls only switch the
    # active locale.
    def self.init(locale : String = "en") : Nil
      unless @@initialized
        ::I18n.config.loaders << HCODE_EMBEDDED_I18N_LOADER
        ::I18n.config.default_locale = :en
        ::I18n.init
        @@initialized = true
      end
      activate(locale)
    end

    # Activates a locale by name (e.g. "en", "ru"). Falls back to :en when the
    # requested locale is not supported.
    def self.activate(locale : String) : Nil
      return unless @@initialized
      loc = SUPPORTED_LOCALES.includes?(locale) ? locale : "en"
      begin
        ::I18n.activate(loc)
      rescue ::I18n::Errors::InvalidLocale
        ::I18n.activate(:en)
      end
    end

    def self.available_locales : Array(String)
      SUPPORTED_LOCALES.to_a
    end

    # Translates a key with optional interpolation params. Returns the key
    # itself (rather than raising) when the translation is missing, so a bad
    # key never crashes the UI.
    def self.t(key : String, **kwargs) : String
      ::I18n.t!(key, **kwargs)
    rescue ::I18n::Errors::MissingTranslation
      key
    end

    def self.t(key : String, params : Hash | NamedTuple | Nil = nil) : String
      ::I18n.t!(key, params)
    rescue ::I18n::Errors::MissingTranslation
      key
    end

    # Resolves the locale to use, in priority order: explicit override, env
    # `HCODE_LANG`, system `LANG`/`LC_ALL`, fallback "en".
    def self.resolve_locale(config_lang : String? = nil, env = ENV) : String
      if lang = config_lang
        return lang if SUPPORTED_LOCALES.includes?(lang)
      end
      if env_lang = env["HCODE_LANG"]?
        resolved = parse_lang(env_lang)
        return resolved if SUPPORTED_LOCALES.includes?(resolved)
      end
      {"LC_ALL", "LC_MESSAGES", "LANG"}.each do |var|
        if val = env[var]?
          resolved = parse_lang(val)
          return resolved if SUPPORTED_LOCALES.includes?(resolved)
        end
      end
      "en"
    end

    private def self.parse_lang(raw : String) : String
      # Handles "ru", "ru_RU", "ru.UTF-8", "ru_RU.UTF-8".
      raw.split('.')[0].split('_')[0].downcase
    end
  end
end

# Top-level shortcut so call sites stay short: `Hcode.t("status.done")`.
module Hcode
  def self.t(key : String, **kwargs) : String
    I18n.t(key, **kwargs)
  end

  def self.t(key : String, params : Hash | NamedTuple | Nil = nil) : String
    I18n.t(key, params)
  end
end
