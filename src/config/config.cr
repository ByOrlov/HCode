module Hcode
  module Config
    class Config
      property model : String = "kimi-for-coding"
      property provider_name : String = "moonshot"
      property thinking_effort : String = "medium"
      property permission_mode : String = "manual"
      property api_key : String = ""
      property endpoint : String = "https://api.kimi.com/coding/v1"
      property zai_api_key : String = ""
      property zai_endpoint : String = "https://api.z.ai/api/paas/v4"
      property zai_model : String = "glm-4.6"
      property zai_coding_plan_endpoint : String = "https://api.z.ai/api/coding/paas/v4"
      property zai_coding_plan_model : String = "glm-5.2"
      property max_steps : Int32 = 100
      property max_context_tokens : Int32 = 262144
      property temperature : Float64? = nil
      property proxy : String? = nil

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

            val = val.strip('"').strip('\'') if val.starts_with?('"') || val.starts_with?('\'')

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
            when {"agent", "max_steps"}      then config.max_steps = val.to_i? || 100
            when {"agent", "max_context_tokens"} then config.max_context_tokens = val.to_i? || 262144
            when {"agent", "temperature"}    then config.temperature = val.to_f64?
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
          s << "default = \"#{@model}\"\n"
          s << "thinking_effort = \"#{@thinking_effort}\"\n"
          s << '\n'
          s << "[permission]\n"
          s << "mode = \"#{@permission_mode}\"\n"
          s << '\n'
          s << "[provider]\n"
          s << "default = \"#{@provider_name}\"\n"
          s << '\n'
          s << "[provider.moonshot]\n"
          s << "api_key = \"#{@api_key}\"\n"
          s << "endpoint = \"#{@endpoint}\"\n"
          s << '\n'
          s << "[provider.zai]\n"
          s << "api_key = \"#{@zai_api_key}\"\n"
          s << "endpoint = \"#{@zai_endpoint}\"\n"
          s << "model = \"#{@zai_model}\"\n"
          s << '\n'
          s << "[provider.zai-coding-plan]\n"
          s << "endpoint = \"#{@zai_coding_plan_endpoint}\"\n"
          s << "model = \"#{@zai_coding_plan_model}\"\n"
          s << '\n'
          s << "[agent]\n"
          s << "max_steps = #{@max_steps}\n"
          s << "max_context_tokens = #{@max_context_tokens}\n"
          if temp = @temperature
            s << "temperature = #{temp}\n"
          end
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
    end
  end
end
