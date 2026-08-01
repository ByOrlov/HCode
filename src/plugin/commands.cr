require "json"
require "file"
require "./types"

module Hcode
  module Plugin
    module CommandLoader
      def self.load(path : String, plugin_id : String, fallback_name : String? = nil) : PluginCommandDef?
        text = File.read(path)
      rescue
        nil
      else
        parse_command_text(text, path, plugin_id, fallback_name)
      end

      def self.parse_command_text(text : String, path : String,
                                  plugin_id : String, fallback_name : String?) : PluginCommandDef
        frontmatter, body = split_frontmatter(text)

        fm = frontmatter
        name = fm["name"]?.try(&.to_s) || fallback_name || File.basename(path, ".md")
        description = fm["description"]?.try(&.to_s) || description_from_body(body)

        PluginCommandDef.new(
          plugin_id: plugin_id,
          name: name,
          description: description,
          body: body.strip,
          path: File.expand_path(path),
        )
      end

      def self.expand_arguments(body : String, args : String) : String
        if body.includes?("$ARGUMENTS")
          body.gsub("$ARGUMENTS", args)
        elsif !args.strip.empty?
          "#{body}\n\nARGUMENTS: #{args}"
        else
          body
        end
      end

      private def self.split_frontmatter(text : String) : {Hash(String, JSON::Any), String}
        lines = text.lines(chomp: true)
        empty = {} of String => JSON::Any

        return {empty, text} unless lines[0]?.try(&.strip) == "---"

        close_idx = (1...lines.size).find { |i| lines[i].strip == "---" }
        return {empty, text} unless close_idx

        yaml_text = lines[1...close_idx].join('\n')
        body = lines[(close_idx + 1)..].join('\n')

        fm = parse_simple_yaml(yaml_text)
        {fm, body}
      end

      private def self.parse_simple_yaml(text : String) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        text.each_line do |raw|
          line = raw.strip
          next if line.empty? || line.starts_with?('#')
          idx = line.index(':')
          next unless idx
          key = line[0...idx].strip
          val = line[(idx + 1)..].strip.strip('"')
          result[key] = JSON::Any.new(val) unless val.empty?
        end
        result
      end

      private def self.description_from_body(body : String) : String
        first_line = body.strip.lines.first?.try(&.strip) || ""
        return "No description provided." if first_line.empty?
        return first_line if first_line.size <= 240
        "#{first_line[0, 239]}\u2026"
      end
    end
  end
end
