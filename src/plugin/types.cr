require "json"
require "../mcp/config"
require "../hooks/engine"

module Hcode
  module Plugin
    PLUGIN_NAME_REGEX = /^[a-z0-9][a-z0-9_-]{0,63}$/

    def self.normalize_id(name : String) : String
      name.downcase
    end

    enum PluginSource
      LocalPath
      ZipUrl
      Github

      def to_s : String
        case self
        in LocalPath then "local-path"
        in ZipUrl    then "zip-url"
        in Github    then "github"
        end
      end

      def self.parse?(s : String) : PluginSource?
        case s
        when "local-path" then LocalPath
        when "zip-url"    then ZipUrl
        when "github"     then Github
        else                   nil
        end
      end
    end

    enum PluginState
      Ok
      Error
    end

    enum PluginManifestKind
      PluginRoot
      PluginDir
    end

    enum DiagnosticSeverity
      Error
      Warn
      Info

      def to_s : String
        case self
        in Error then "error"
        in Warn  then "warn"
        in Info  then "info"
        end
      end
    end

    struct PluginDiagnostic
      property severity : DiagnosticSeverity
      property message : String

      def initialize(@severity : DiagnosticSeverity, @message : String)
      end
    end

    struct PluginAuthor
      property name : String?
      property email : String?

      def initialize(@name : String? = nil, @email : String? = nil)
      end
    end

    struct PluginSessionStart
      property skill : String

      def initialize(@skill : String)
      end
    end

    struct PluginInterface
      property display_name : String?
      property short_description : String?
      property long_description : String?
      property developer_name : String?
      property website_url : String?

      def initialize(@display_name : String? = nil,
                     @short_description : String? = nil,
                     @long_description : String? = nil,
                     @developer_name : String? = nil,
                     @website_url : String? = nil)
      end
    end

    struct PluginCommandEntry
      property path : String
      property name : String

      def initialize(@path : String, @name : String)
      end
    end

    struct PluginCommandDef
      property plugin_id : String
      property name : String
      property description : String
      property body : String
      property path : String

      def initialize(@plugin_id : String, @name : String, @description : String,
                     @body : String, @path : String)
      end
    end

    struct PluginManifest
      property name : String
      property version : String?
      property description : String?
      property keywords : Array(String)
      property author : PluginAuthor?
      property homepage : String?
      property license : String?
      property skills : Array(String)
      property session_start : PluginSessionStart?
      property mcp_servers : Hash(String, Mcp::McpServerConfig)
      property hooks : Array(Hcode::Hooks::HookDef)
      property commands : Array(PluginCommandEntry)
      property interface : PluginInterface?
      property skill_instructions : String?

      def initialize(@name : String,
                     @version : String? = nil,
                     @description : String? = nil,
                     @keywords : Array(String) = [] of String,
                     @author : PluginAuthor? = nil,
                     @homepage : String? = nil,
                     @license : String? = nil,
                     @skills : Array(String) = [] of String,
                     @session_start : PluginSessionStart? = nil,
                     @mcp_servers : Hash(String, Mcp::McpServerConfig) = {} of String => Mcp::McpServerConfig,
                     @hooks : Array(Hcode::Hooks::HookDef) = [] of Hcode::Hooks::HookDef,
                     @commands : Array(PluginCommandEntry) = [] of PluginCommandEntry,
                     @interface : PluginInterface? = nil,
                     @skill_instructions : String? = nil)
      end
    end

    struct ParsedManifestResult
      property manifest : PluginManifest?
      property manifest_kind : PluginManifestKind?
      property manifest_path : String?
      property shadowed_manifest_path : String?
      property diagnostics : Array(PluginDiagnostic)

      def initialize(@manifest : PluginManifest? = nil,
                     @manifest_kind : PluginManifestKind? = nil,
                     @manifest_path : String? = nil,
                     @shadowed_manifest_path : String? = nil,
                     @diagnostics : Array(PluginDiagnostic) = [] of PluginDiagnostic)
      end

      def has_error? : Bool
        @diagnostics.any? { |d| d.severity.error? }
      end
    end

    struct PluginMcpServerState
      property? enabled : Bool

      def initialize(@enabled : Bool = true)
      end
    end

    struct PluginCapabilityState
      property mcp_servers : Hash(String, PluginMcpServerState)

      def initialize(@mcp_servers : Hash(String, PluginMcpServerState) = {} of String => PluginMcpServerState)
      end
    end

    struct PluginGithubRef
      property kind : String  # "branch" | "tag" | "sha"
      property value : String

      def initialize(@kind : String, @value : String)
      end
    end

    struct PluginGithubMetadata
      property owner : String
      property repo : String
      property ref : PluginGithubRef?
      property installed_sha : String?

      def initialize(@owner : String, @repo : String,
                     @ref : PluginGithubRef? = nil, @installed_sha : String? = nil)
      end
    end

    struct EnabledPluginSessionStart
      property plugin_id : String
      property skill_name : String

      def initialize(@plugin_id : String, @skill_name : String)
      end
    end

    struct ReloadSummary
      property added : Array(String)
      property removed : Array(String)
      property errors : Array({id: String, message: String})

      def initialize(@added : Array(String) = [] of String,
                     @removed : Array(String) = [] of String,
                     @errors : Array({id: String, message: String}) = [] of {id: String, message: String})
      end
    end
  end
end
