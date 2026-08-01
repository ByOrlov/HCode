require "json"
require "file"
require "../mcp/config"
require "./types"

module Hcode
  module Plugin
    KIMI_PLUGIN_ROOT_PATH = "kimi.plugin.json"
    KIMI_PLUGIN_DIR_PATH  = ".kimi-plugin/plugin.json"

    UNSUPPORTED_RUNTIME_FIELDS = ["tools", "apps", "inject", "configFile", "config_file", "bootstrap"]

    module ManifestParser
      def self.parse(plugin_root : String) : ParsedManifestResult
        root_json_path = File.join(plugin_root, KIMI_PLUGIN_ROOT_PATH)
        dir_json_path = File.join(plugin_root, KIMI_PLUGIN_DIR_PATH)
        root_json_exists = File.file?(root_json_path)
        dir_json_exists = File.file?(dir_json_path)

        unless root_json_exists || dir_json_exists
          return ParsedManifestResult.new(
            diagnostics: [PluginDiagnostic.new(
              DiagnosticSeverity::Error,
              "No manifest at #{KIMI_PLUGIN_ROOT_PATH} or #{KIMI_PLUGIN_DIR_PATH}"
            )]
          )
        end

        manifest_path = root_json_exists ? root_json_path : dir_json_path
        manifest_kind = root_json_exists ? PluginManifestKind::PluginRoot : PluginManifestKind::PluginDir
        shadowed = (root_json_exists && dir_json_exists) ? dir_json_path : nil

        raw_text = File.read(manifest_path)
        raw = JSON.parse(raw_text)
        diagnostics = [] of PluginDiagnostic

        unless raw.as_h?
          return ParsedManifestResult.new(
            manifest_kind: manifest_kind,
            manifest_path: manifest_path,
            shadowed_manifest_path: shadowed,
            diagnostics: [PluginDiagnostic.new(DiagnosticSeverity::Error, "manifest must be a JSON object")]
          )
        end

        h = raw.as_h

        name = h["name"]?.try(&.as_s?).try(&.strip) || ""
        if name.empty?
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Error, "\"name\" is required")
          return ParsedManifestResult.new(manifest_kind: manifest_kind, manifest_path: manifest_path,
                                          shadowed_manifest_path: shadowed, diagnostics: diagnostics)
        end
        unless name.matches?(PLUGIN_NAME_REGEX)
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Error,
            "\"name\" must match #{PLUGIN_NAME_REGEX} (got \"#{name}\")")
          return ParsedManifestResult.new(manifest_kind: manifest_kind, manifest_path: manifest_path,
                                          shadowed_manifest_path: shadowed, diagnostics: diagnostics)
        end

        skills = resolve_skills_field(plugin_root, h["skills"]?, diagnostics)
        if h["skills"]?.nil?
          root_skill_md = File.join(plugin_root, "SKILL.md")
          if File.file?(root_skill_md)
            skills = [plugin_root]
          end
        end

        skill_instructions = h["skillInstructions"]?.try(&.as_s?)

        record_unsupported_fields(h, diagnostics)

        session_start = read_session_start(h["sessionStart"]?, diagnostics)

        mcp_servers = read_mcp_servers(plugin_root, h["mcpServers"]?, diagnostics)

        hooks = read_hooks(h["hooks"]?, diagnostics)

        commands = read_commands(plugin_root, h["commands"]?, diagnostics)

        author = read_author(h["author"]?)
        interface = read_interface(h["interface"]?)
        keywords = read_string_array(h["keywords"]?)

        manifest = PluginManifest.new(
          name: name,
          version: read_string(h["version"]?),
          description: read_string(h["description"]?),
          keywords: keywords,
          author: author,
          homepage: read_string(h["homepage"]?),
          license: read_string(h["license"]?),
          skills: skills,
          session_start: session_start,
          mcp_servers: mcp_servers,
          hooks: hooks,
          commands: commands,
          interface: interface,
          skill_instructions: skill_instructions,
        )

        ParsedManifestResult.new(
          manifest: manifest,
          manifest_kind: manifest_kind,
          manifest_path: manifest_path,
          shadowed_manifest_path: shadowed,
          diagnostics: diagnostics,
        )
      rescue ex : JSON::ParseException
        ParsedManifestResult.new(
          manifest_kind: manifest_kind,
          manifest_path: manifest_path,
          shadowed_manifest_path: shadowed,
          diagnostics: [PluginDiagnostic.new(DiagnosticSeverity::Error,
            "Failed to parse manifest: #{ex.message}")],
        )
      rescue ex
        ParsedManifestResult.new(
          diagnostics: [PluginDiagnostic.new(DiagnosticSeverity::Error,
            "Failed to read manifest: #{ex.message}")],
        )
      end

      private def self.resolve_skills_field(plugin_root : String, raw : JSON::Any?,
                                            diagnostics : Array(PluginDiagnostic)) : Array(String)
        return [] of String if raw.nil?

        entries = [] of String
        case v = raw.raw
        when String
          entries << v
        when Array(JSON::Any)
          entries.concat(v.map(&.to_s))
        else
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Error,
            "\"skills\" must be a string or string[]")
          return [] of String
        end

        root_real = realpath_safe(plugin_root)
        resolved = [] of String
        entries.each do |entry|
          unless entry.starts_with?("./")
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Error,
              "\"skills\" path must start with \"./\" (got \"#{entry}\")")
            next
          end
          absolute = File.expand_path(entry, plugin_root)
          real = realpath_safe(absolute)
          unless within?(real, root_real)
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Error,
              "\"skills\" path resolves outside the plugin (#{entry})")
            next
          end
          unless Dir.exists?(real)
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
              "\"skills\" path is not a directory (#{entry})")
            next
          end
          resolved << real
        end
        resolved
      end

      private def self.read_session_start(raw : JSON::Any?,
                                          diagnostics : Array(PluginDiagnostic)) : PluginSessionStart?
        return nil if raw.nil?
        h = raw.as_h?
        unless h
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"sessionStart\" must be an object")
          return nil
        end
        skill = h["skill"]?.try(&.as_s?).try(&.strip) || ""
        if skill.empty?
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"sessionStart.skill\" is required when sessionStart is present")
          return nil
        end
        PluginSessionStart.new(skill)
      end

      private def self.read_mcp_servers(plugin_root : String, raw : JSON::Any?,
                                       diagnostics : Array(PluginDiagnostic)) : Hash(String, Mcp::McpServerConfig)
        result = {} of String => Mcp::McpServerConfig
        return result if raw.nil?

        h = raw.as_h?
        unless h
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"mcpServers\" must be an object")
          return result
        end

        root_real = realpath_safe(plugin_root)

        h.each do |name, spec|
          trimmed = name.strip
          next if trimmed.empty?

          spec_h = spec.as_h?
          unless spec_h
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
              "Invalid MCP server \"#{trimmed}\": must be an object")
            next
          end

          cfg = Mcp::ConfigLoader.from_any_json(trimmed, spec_h)
          cfg = normalize_plugin_mcp_server(plugin_root, root_real, trimmed, cfg, diagnostics)
          result[trimmed] = cfg if cfg
        end
        result
      end

      private def self.normalize_plugin_mcp_server(plugin_root : String, root_real : String,
                                                    name : String, cfg : Mcp::McpServerConfig,
                                                    diagnostics : Array(PluginDiagnostic)) : Mcp::McpServerConfig?
        return cfg if cfg.remote?

        command = cfg.command
        if command.starts_with?("./")
          resolved = resolve_plugin_path(plugin_root, root_real, "mcpServers.#{name}.command",
                                         command, diagnostics)
          return nil unless resolved
          cfg.command = resolved
        elsif command.includes?('/') || Path.new(command).absolute?
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"mcpServers.#{name}.command\" must be a PATH command or start with \"./\"")
          return nil
        end

        if cwd = cfg.cwd
          if cwd.starts_with?("./")
            resolved = resolve_plugin_path(plugin_root, root_real, "mcpServers.#{name}.cwd",
                                           cwd, diagnostics)
            return nil unless resolved
            cfg.cwd = resolved
          end
        end

        cfg
      end

      private def self.read_hooks(raw : JSON::Any?,
                                  diagnostics : Array(PluginDiagnostic)) : Array(Hooks::HookDef)
        return [] of Hooks::HookDef if raw.nil?

        arr = raw.as_a?
        unless arr
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"hooks\" must be an array")
          return [] of Hooks::HookDef
        end

        hooks = [] of Hooks::HookDef
        arr.each_with_index do |entry, i|
          h = entry.as_h?
          unless h
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
              "Invalid hook at index #{i}: must be an object")
            next
          end

          event = h["event"]?.try(&.to_s) || ""
          command = h["command"]?.try(&.to_s) || ""
          matcher = h["matcher"]?.try(&.to_s) || ""
          timeout = h["timeout"]?.try(&.as_i?) || 30

          if event.empty? || command.empty?
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
              "Invalid hook at index #{i}: \"event\" and \"command\" are required")
            next
          end

          hooks << Hooks::HookDef.new(event, command, matcher, timeout)
        end
        hooks
      end

      private def self.read_commands(plugin_root : String, raw : JSON::Any?,
                                     diagnostics : Array(PluginDiagnostic)) : Array(PluginCommandEntry)
        return [] of PluginCommandEntry if raw.nil?

        entries = [] of String
        case v = raw.raw
        when String
          entries << v
        when Array(JSON::Any)
          entries.concat(v.map(&.to_s))
        else
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"commands\" must be a string or string[]")
          return [] of PluginCommandEntry
        end

        files = [] of PluginCommandEntry
        root_real = realpath_safe(plugin_root)

        entries.each do |entry|
          resolved = resolve_plugin_path(plugin_root, root_real, "commands", entry, diagnostics)
          next unless resolved

          if Dir.exists?(resolved)
            walk_markdown(resolved, resolved, files)
          elsif File.file?(resolved) && resolved.ends_with?(".md")
            files << PluginCommandEntry.new(resolved, command_name_from_file(resolved, File.dirname(resolved)))
          else
            diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
              "\"commands\" entry must be a directory or .md file (#{entry})")
          end
        end

        files.sort_by(&.name)
      end

      private def self.walk_markdown(root : String, dir : String, out_files : Array(PluginCommandEntry)) : Nil
        entries = Dir.children(dir).sort
      rescue File::Error
        return
      else
        entries.each do |entry|
          full = File.join(dir, entry)
          if Dir.exists?(full)
            walk_markdown(root, full, out_files)
          elsif File.file?(full) && entry.ends_with?(".md")
            out_files << PluginCommandEntry.new(full, command_name_from_file(full, root))
          end
        end
      end

      private def self.command_name_from_file(file : String, root : String) : String
        rel = Path.new(file).relative_to(root).to_s
        rel = rel.rchop(".md")
        rel.gsub(File::SEPARATOR, '/')
      end

      private def self.resolve_plugin_path(plugin_root : String, root_real : String,
                                           field : String, value : String,
                                           diagnostics : Array(PluginDiagnostic)) : String?
        unless value.starts_with?("./")
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"#{field}\" path must start with \"./\" (got \"#{value}\")")
          return nil
        end
        absolute = File.expand_path(value, plugin_root)
        real = realpath_safe(absolute)
        unless within?(real, root_real)
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Warn,
            "\"#{field}\" path resolves outside the plugin (#{value})")
          return nil
        end
        real
      end

      private def self.record_unsupported_fields(h : Hash(String, JSON::Any),
                                                  diagnostics : Array(PluginDiagnostic)) : Nil
        UNSUPPORTED_RUNTIME_FIELDS.each do |field|
          next unless h.has_key?(field)
          diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Info,
            "\"#{field}\" is present but not supported by Kimi plugins")
        end
      end

      private def self.read_author(raw : JSON::Any?) : PluginAuthor?
        return nil if raw.nil?
        case v = raw.raw
        when String
          v.empty? ? nil : PluginAuthor.new(name: v)
        when Hash
          name = v["name"]?.try(&.to_s)
          email = v["email"]?.try(&.to_s)
          (name || email) ? PluginAuthor.new(name, email) : nil
        else
          nil
        end
      end

      private def self.read_interface(raw : JSON::Any?) : PluginInterface?
        return nil if raw.nil?
        h = raw.as_h?
        return nil unless h

        iface = PluginInterface.new(
          display_name: h["displayName"]?.try(&.as_s?),
          short_description: h["shortDescription"]?.try(&.as_s?),
          long_description: h["longDescription"]?.try(&.as_s?),
          developer_name: h["developerName"]?.try(&.as_s?),
          website_url: h["websiteURL"]?.try(&.as_s?),
        )
        iface.display_name || iface.short_description || iface.long_description ||
          iface.developer_name || iface.website_url ? iface : nil
      end

      private def self.read_string(v : JSON::Any?) : String?
        return nil if v.nil?
        s = v.as_s?
        return nil unless s
        t = s.strip
        t.empty? ? nil : t
      end

      private def self.read_string_array(v : JSON::Any?) : Array(String)
        return [] of String unless v
        arr = v.as_a?
        return [] of String unless arr
        arr.map(&.to_s)
      end

      private def self.realpath_safe(path : String) : String
        File.realpath(path)
      rescue
        path
      end

      private def self.within?(child : String, parent : String) : Bool
        rel = Path.new(child).relative_to(parent).to_s
        rel == "." || (!rel.starts_with?("..") && !Path.new(rel).absolute?)
      end
    end
  end
end
