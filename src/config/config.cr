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
      property notifications : Notify::Config = Notify::Config.default

      def initialize
      end

      def self.load(path : String? = nil) : Config
        config = Config.new

        config_path = path || default_config_path

        if File.exists?(config_path)
          content = File.read(config_path)
          config = parse_toml(content)
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
        if proxy = ENV["HTTP_PROXY"]? || ENV["HTTPS_PROXY"]? || ENV["ALL_PROXY"]?
          config.proxy = proxy
        end

        config
      end

      def self.default_config_path : String
        home = ENV["HOME"]? || "/tmp"
        hcode_home = ENV["HCODE_HOME"]? || File.join(home, ".hcode")
        File.join(hcode_home, "config.toml")
      end

      def self.parse_toml(content : String) : Config
        config = Config.new

        current_section = ""

        content.each_line do |line|
          line = line.strip
          next if line.empty? || line.starts_with?('#')

          if line =~ /^\[(.+)\]$/
            current_section = $1
          elsif line =~ /^(\w+)\s*=\s*(.+)$/
            key = $1
            val = $2.strip

            is_str = val.starts_with?('"') || val.starts_with?('\'')
            val = val.strip('"').strip('\'') if is_str

            case {current_section, key}
            when {"model", "default"}        then config.model = val
            when {"model", "thinking_effort"} then config.thinking_effort = val
            when {"permission", "mode"}      then config.permission_mode = val
            when {"provider", "default"}     then config.provider_name = val
            when {"provider.moonshot", "api_key"} then config.api_key = val
            when {"provider.moonshot", "endpoint"} then config.endpoint = val
            when {"provider.zai", "api_key"}  then config.zai_api_key = val
            when {"provider.zai", "endpoint"} then config.zai_endpoint = val
            when {"provider.zai", "model"}    then config.zai_model = val
            when {"provider.zai-coding-plan", "endpoint"} then config.zai_coding_plan_endpoint = val
            when {"provider.zai-coding-plan", "model"}    then config.zai_coding_plan_model = val
            when {"provider.ollama", "endpoint"} then config.ollama_endpoint = val
            when {"provider.ollama", "model"}    then config.ollama_model = val
            when {"provider.lmstudio", "endpoint"} then config.lmstudio_endpoint = val
            when {"provider.lmstudio", "model"}    then config.lmstudio_model = val
            when {"agent", "max_steps"}      then config.max_steps = val.to_i? || 100
            when {"agent", "max_context_tokens"} then config.max_context_tokens = val.to_i? || 262144
            when {"agent", "temperature"}    then config.temperature = val.to_f64?
            # [notifications]
            when {"notifications", "enabled"}   then config.notifications.enabled = parse_bool(val)
            when {"notifications", "condition"} then config.notifications.condition = val
            # [notifications.sound]
            when {"notifications.sound", "enabled"}        then config.notifications.sound_enabled = parse_bool(val)
            when {"notifications.sound", "done"}           then config.notifications.sound_done = val
            when {"notifications.sound", "input_required"} then config.notifications.sound_input_required = val
            when {"notifications.sound", "working"}        then config.notifications.sound_working = val
            # [notifications.terminal]
            when {"notifications.terminal", "enabled"} then config.notifications.terminal_enabled = parse_bool(val)
            # [notifications.webhook]
            when {"notifications.webhook", "enabled"}    then config.notifications.webhook_enabled = parse_bool(val)
            when {"notifications.webhook", "url"}        then config.notifications.webhook_url = val
            when {"notifications.webhook", "method"}     then config.notifications.webhook_method = val
            when {"notifications.webhook", "timeout_ms"} then config.notifications.webhook_timeout_ms = val.to_i? || 5000
            when {"notifications.webhook", "secret"}     then config.notifications.webhook_secret = val
            end
          end
        end

        config
      end

      def save(path : String? = nil) : Nil
        config_path = path || Config.default_config_path
        dir = File.dirname(config_path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        content = String.build do |s|
          s << "[model]\n"
          if m = @model
            s << "default = \"#{m}\"\n"
          end
          s << "thinking_effort = \"#{@thinking_effort}\"\n"
          s << '\n'
          s << "[permission]\n"
          s << "mode = \"#{@permission_mode}\"\n"
          s << '\n'
          s << "[provider]\n"
          if pn = @provider_name
            s << "default = \"#{pn}\"\n"
          end
          s << '\n'
          if @api_key || @endpoint
            s << "[provider.moonshot]\n"
            if k = @api_key
              s << "api_key = \"#{k}\"\n"
            end
            if ep = @endpoint
              s << "endpoint = \"#{ep}\"\n"
            end
            s << '\n'
          end
          s << "[provider.zai]\n"
          s << "api_key = \"#{@zai_api_key}\"\n"
          s << "endpoint = \"#{@zai_endpoint}\"\n"
          s << "model = \"#{@zai_model}\"\n"
          s << '\n'
          s << "[provider.zai-coding-plan]\n"
          s << "endpoint = \"#{@zai_coding_plan_endpoint}\"\n"
          s << "model = \"#{@zai_coding_plan_model}\"\n"
          s << '\n'
          if @ollama_endpoint || @ollama_model
            s << "[provider.ollama]\n"
            if ep = @ollama_endpoint
              s << "endpoint = \"#{ep}\"\n"
            end
            if m = @ollama_model
              s << "model = \"#{m}\"\n"
            end
            s << '\n'
          end
          if @lmstudio_endpoint || @lmstudio_model
            s << "[provider.lmstudio]\n"
            if ep = @lmstudio_endpoint
              s << "endpoint = \"#{ep}\"\n"
            end
            if m = @lmstudio_model
              s << "model = \"#{m}\"\n"
            end
            s << '\n'
          end
          s << "[agent]\n"
          s << "max_steps = #{@max_steps}\n"
          s << "max_context_tokens = #{@max_context_tokens}\n"
          if temp = @temperature
            s << "temperature = #{temp}\n"
          end
          s << '\n'
          s << "[notifications]\n"
          s << "enabled = #{@notifications.enabled}\n"
          s << "condition = \"#{@notifications.condition}\"\n"
          s << '\n'
          s << "[notifications.sound]\n"
          s << "enabled = #{@notifications.sound_enabled}\n"
          s << "done = \"#{@notifications.sound_done}\"\n"
          s << "input_required = \"#{@notifications.sound_input_required}\"\n"
          s << "working = \"#{@notifications.sound_working}\"\n"
          s << '\n'
          s << "[notifications.terminal]\n"
          s << "enabled = #{@notifications.terminal_enabled}\n"
          s << '\n'
          s << "[notifications.webhook]\n"
          s << "enabled = #{@notifications.webhook_enabled}\n"
          s << "url = \"#{@notifications.webhook_url}\"\n"
          s << "method = \"#{@notifications.webhook_method}\"\n"
          s << "timeout_ms = #{@notifications.webhook_timeout_ms}\n"
          s << "secret = \"#{@notifications.webhook_secret}\"\n"
        end

        File.write(config_path, content)
      end

      def ensure_hcode_home : Nil
        home = ENV["HOME"]? || "/tmp"
        hcode_home = ENV["HCODE_HOME"]? || File.join(home, ".hcode")
        Dir.mkdir_p(hcode_home) unless Dir.exists?(hcode_home)
        sessions_dir = File.join(hcode_home, "sessions")
        Dir.mkdir_p(sessions_dir) unless Dir.exists?(sessions_dir)
      end

      # Returns true when the current provider_name + credentials are sufficient
      # to attempt a connection. Used to decide whether the setup wizard runs.
      # Does NOT validate the key — only that one is present.
      def provider_configured? : Bool
        case provider_name
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

      private def self.parse_bool(val : String) : Bool
        val.downcase.in?("true", "1", "yes", "on")
      end
    end
  end
end
