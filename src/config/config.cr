require "json"
require "../mcp/config"

module Hcode
  module Config
    class Config
      property model : String? = nil
      property provider_name : String? = nil
      property thinking_effort : String = "medium"
      property permission_mode : String = "manual"
      property api_key : String? = nil
      property endpoint : String? = nil
      property zai_api_key : String = ""
      property zai_endpoint : String = "https://api.z.ai/api/paas/v4"
      property zai_model : String = "glm-4.6"
      property zai_coding_plan_endpoint : String = "https://api.z.ai/api/coding/paas/v4"
      property zai_coding_plan_model : String = "glm-5.2"
      property ollama_endpoint : String? = nil
      property ollama_model : String? = nil
      property lmstudio_endpoint : String? = nil
      property lmstudio_model : String? = nil
      property max_steps : Int32 = 100
      property max_context_tokens : Int32 = 262144
      property temperature : Float64? = nil
      property proxy : String? = nil
      property language : String? = nil
      property debug_zones : Bool = false
      property notifications : Notify::Config = Notify::Config.default
      property hooks : Array(Hooks::HookDef) = [] of Hooks::HookDef
      property mcp_servers : Array(Mcp::McpServerConfig) = [] of Mcp::McpServerConfig

      def initialize
      end

      def self.load(path : String? = nil) : Config
        config = Config.new

        config_path = path || default_config_path

        if File.exists?(config_path)
          content = File.read(config_path)
          config = parse_json(content)
        end

        if key = ENV["MOONSHOT_API_KEY"]?
          config.api_key = key
        end
        if key = ENV["ZAI_API_KEY"]?
          config.zai_api_key = key
        end
        if key = ENV["ZHIPU_API_KEY"]?
          config.zai_api_key = key
        end
        if ep = ENV["MOONSHOT_ENDPOINT"]?
          config.endpoint = ep
        end
        if ep = ENV["ZAI_ENDPOINT"]?
          config.zai_endpoint = ep
        end
        if ep = ENV["ZAI_CODING_PLAN_ENDPOINT"]?
          config.zai_coding_plan_endpoint = ep
        end
        if ep = ENV["OLLAMA_ENDPOINT"]?
          config.ollama_endpoint = ep
        end
        if model = ENV["OLLAMA_MODEL"]?
          config.ollama_model = model
        end
        if ep = ENV["LMSTUDIO_ENDPOINT"]?
          config.lmstudio_endpoint = ep
        end
        if model = ENV["LMSTUDIO_MODEL"]?
          config.lmstudio_model = model
        end
        if model = ENV["MOONSHOT_MODEL"]?
          config.model = model
        end
        if model = ENV["ZAI_MODEL"]?
          config.zai_model = model
        end
        if model = ENV["ZAI_CODING_PLAN_MODEL"]?
          config.zai_coding_plan_model = model
        end
        if provider = ENV["HCODE_PROVIDER"]?
          config.provider_name = provider
        end
        if lang = ENV["HCODE_LANG"]?
          config.language = lang
        end
        if proxy = ENV["HTTP_PROXY"]? || ENV["HTTPS_PROXY"]? || ENV["ALL_PROXY"]?
          config.proxy = proxy
        end

        config
      end

      def self.default_config_path : String
        home = ENV["HOME"]? || "/tmp"
        hcode_home = ENV["HCODE_HOME"]? || File.join(home, ".hcode")
        File.join(hcode_home, "config.json")
      end

      def self.parse_json(content : String) : Config
        config = Config.new
        root = JSON.parse(content)

        if model = root["model"]?.try(&.as_h?)
          config.model = model["default"]?.try(&.as_s?)
          config.thinking_effort = model["thinking_effort"]?.try(&.as_s?) || "medium"
        end

        if perm = root["permission"]?.try(&.as_h?)
          config.permission_mode = perm["mode"]?.try(&.as_s?) || "manual"
        end

        if provider = root["provider"]?.try(&.as_h?)
          config.provider_name = provider["default"]?.try(&.as_s?)
          if moonshot = provider["moonshot"]?.try(&.as_h?)
            config.api_key = moonshot["api_key"]?.try(&.as_s?)
            config.endpoint = moonshot["endpoint"]?.try(&.as_s?)
          end
          if zai = provider["zai"]?.try(&.as_h?)
            config.zai_api_key = zai["api_key"]?.try(&.as_s?) || ""
            config.zai_endpoint = zai["endpoint"]?.try(&.as_s?) || config.zai_endpoint
            config.zai_model = zai["model"]?.try(&.as_s?) || config.zai_model
          end
          if zcp = provider["zai-coding-plan"]?.try(&.as_h?)
            config.zai_coding_plan_endpoint = zcp["endpoint"]?.try(&.as_s?) || config.zai_coding_plan_endpoint
            config.zai_coding_plan_model = zcp["model"]?.try(&.as_s?) || config.zai_coding_plan_model
          end
          if ollama = provider["ollama"]?.try(&.as_h?)
            config.ollama_endpoint = ollama["endpoint"]?.try(&.as_s?)
            config.ollama_model = ollama["model"]?.try(&.as_s?)
          end
          if lmstudio = provider["lmstudio"]?.try(&.as_h?)
            config.lmstudio_endpoint = lmstudio["endpoint"]?.try(&.as_s?)
            config.lmstudio_model = lmstudio["model"]?.try(&.as_s?)
          end
        end

        if agent = root["agent"]?.try(&.as_h?)
          config.max_steps = agent["max_steps"]?.try(&.as_i?) || 100
          config.max_context_tokens = agent["max_context_tokens"]?.try(&.as_i?) || 262144
          config.temperature = agent["temperature"]?.try(&.as_f?)
        end

        if ui = root["ui"]?.try(&.as_h?)
          config.language = ui["language"]?.try(&.as_s?)
          config.debug_zones = ui["debug_zones"]?.try(&.as_bool?) || false
        end

        if notif = root["notifications"]?.try(&.as_h?)
          config.notifications.enabled = notif["enabled"]?.try(&.as_bool?) || config.notifications.enabled
          config.notifications.condition = notif["condition"]?.try(&.as_s?) || config.notifications.condition
          if sound = notif["sound"]?.try(&.as_h?)
            config.notifications.sound_enabled = sound["enabled"]?.try(&.as_bool?) || config.notifications.sound_enabled
            config.notifications.sound_done = sound["done"]?.try(&.as_s?) || ""
            config.notifications.sound_input_required = sound["input_required"]?.try(&.as_s?) || ""
            config.notifications.sound_working = sound["working"]?.try(&.as_s?) || ""
          end
          if term = notif["terminal"]?.try(&.as_h?)
            config.notifications.terminal_enabled = term["enabled"]?.try(&.as_bool?) || config.notifications.terminal_enabled
          end
          if webhook = notif["webhook"]?.try(&.as_h?)
            config.notifications.webhook_enabled = webhook["enabled"]?.try(&.as_bool?) || config.notifications.webhook_enabled
            config.notifications.webhook_url = webhook["url"]?.try(&.as_s?) || ""
            config.notifications.webhook_method = webhook["method"]?.try(&.as_s?) || "POST"
            config.notifications.webhook_timeout_ms = webhook["timeout_ms"]?.try(&.as_i?) || 5000
            config.notifications.webhook_secret = webhook["secret"]?.try(&.as_s?) || ""
          end
        end

        config.hooks = parse_hooks_array(root["hooks"]?.try(&.as_a?))

        # MCP servers: load from mcp.json sources (user-global, project-root,
        # project-local) and merge by name.
        home = ENV["HOME"]? || "/tmp"
        config.mcp_servers = Mcp::ConfigLoader.load(home, cwd: Dir.current)

        config
      end

      def save(path : String? = nil) : Nil
        config_path = path || Config.default_config_path
        dir = File.dirname(config_path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        root = JSON.build(indent: 2) do |json|
          json.object do
            json.field("model") do
              json.object do
                if m = @model
                  json.field("default", m)
                end
                json.field("thinking_effort", @thinking_effort)
              end
            end

            json.field("permission") do
              json.object do
                json.field("mode", @permission_mode)
              end
            end

            json.field("provider") do
              json.object do
                if pn = @provider_name
                  json.field("default", pn)
                end
                if @api_key || @endpoint
                  json.field("moonshot") do
                    json.object do
                      if k = @api_key
                        json.field("api_key", k)
                      end
                      if ep = @endpoint
                        json.field("endpoint", ep)
                      end
                    end
                  end
                end
                json.field("zai") do
                  json.object do
                    json.field("api_key", @zai_api_key)
                    json.field("endpoint", @zai_endpoint)
                    json.field("model", @zai_model)
                  end
                end
                json.field("zai-coding-plan") do
                  json.object do
                    json.field("endpoint", @zai_coding_plan_endpoint)
                    json.field("model", @zai_coding_plan_model)
                  end
                end
                if @ollama_endpoint || @ollama_model
                  json.field("ollama") do
                    json.object do
                      if ep = @ollama_endpoint
                        json.field("endpoint", ep)
                      end
                      if m = @ollama_model
                        json.field("model", m)
                      end
                    end
                  end
                end
                if @lmstudio_endpoint || @lmstudio_model
                  json.field("lmstudio") do
                    json.object do
                      if ep = @lmstudio_endpoint
                        json.field("endpoint", ep)
                      end
                      if m = @lmstudio_model
                        json.field("model", m)
                      end
                    end
                  end
                end
              end
            end

            json.field("agent") do
              json.object do
                json.field("max_steps", @max_steps)
                json.field("max_context_tokens", @max_context_tokens)
                if temp = @temperature
                  json.field("temperature", temp)
                end
              end
            end

            json.field("ui") do
              json.object do
                if lang = @language
                  json.field("language", lang)
                end
                json.field("debug_zones", @debug_zones)
              end
            end

            json.field("notifications") do
              json.object do
                json.field("enabled", @notifications.enabled)
                json.field("condition", @notifications.condition)
                json.field("sound") do
                  json.object do
                    json.field("enabled", @notifications.sound_enabled)
                    json.field("done", @notifications.sound_done)
                    json.field("input_required", @notifications.sound_input_required)
                    json.field("working", @notifications.sound_working)
                  end
                end
                json.field("terminal") do
                  json.object do
                    json.field("enabled", @notifications.terminal_enabled)
                  end
                end
                json.field("webhook") do
                  json.object do
                    json.field("enabled", @notifications.webhook_enabled)
                    json.field("url", @notifications.webhook_url)
                    json.field("method", @notifications.webhook_method)
                    json.field("timeout_ms", @notifications.webhook_timeout_ms)
                    json.field("secret", @notifications.webhook_secret)
                  end
                end
              end
            end
          end
        end

        File.write(config_path, root + "\n")
      end

      def ensure_hcode_home : Nil
        home = ENV["HOME"]? || "/tmp"
        hcode_home = ENV["HCODE_HOME"]? || File.join(home, ".hcode")
        Dir.mkdir_p(hcode_home) unless Dir.exists?(hcode_home)
        sessions_dir = File.join(hcode_home, "sessions")
        Dir.mkdir_p(sessions_dir) unless Dir.exists?(sessions_dir)
        exceptions_dir = File.join(hcode_home, "exceptions")
        Dir.mkdir_p(exceptions_dir) unless Dir.exists?(exceptions_dir)
      end

      # Returns true when the current provider_name + credentials are sufficient
      # to attempt a connection. Used to decide whether the setup wizard runs.
      # Does NOT validate the key — only that one is present.
      def provider_configured? : Bool
        provider_configured?(provider_name)
      end

      # Same check for an arbitrary provider name — used to decide whether a
      # runtime /provider switch needs to launch the setup wizard.
      def provider_configured?(name : String?) : Bool
        case name
        when "moonshot"        then !api_key.to_s.empty? || oauth_credentials_present?
        when "zai"             then !zai_api_key.empty?
        when "zai-coding-plan" then !zai_api_key.empty?
        when "ollama"          then true
        when "lmstudio"        then true
        when "mock"            then true
        when nil               then false
        else                   !api_key.to_s.empty?
        end
      end

      # OAuth token presence — loaded from ~/.kimi-code/credentials by the
      # entry point and stored on the provider, not the config. The config
      # only knows whether an api_key is set, so this is a best-effort check.
      private def oauth_credentials_present? : Bool
        home = ENV["HOME"]? || "/tmp"
        path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
        File.exists?(path)
      end

      # Provider-specific MCP servers generated from the active provider's
      # credentials. Currently empty — Z.AI web search is handled via the
      # provider's built-in `web_search` tool (injected in ZaiProvider), not
      # through a standalone MCP server.
      def auto_mcp_servers : Array(Mcp::McpServerConfig)
        [] of Mcp::McpServerConfig
      end

      private def self.parse_hooks_array(arr : Array(JSON::Any)?) : Array(Hooks::HookDef)
        return [] of Hooks::HookDef unless arr
        arr.map do |entry|
          h = entry.as_h
          Hooks::HookDef.new(
            event: h["event"]?.try(&.as_s?) || "",
            command: h["command"]?.try(&.as_s?) || "",
            matcher: h["matcher"]?.try(&.as_s?) || "",
            timeout: h["timeout"]?.try(&.as_i?) || 30,
          )
        end
      end
    end
  end
end
