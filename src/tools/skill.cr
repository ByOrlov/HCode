module Hcode
  module Tools
    # Skill — вызов зарегистрированного skill с аргументами и встраивание
    # его промпта в текущий ход через `Context::Memory#add_injection`.
    #
    # Контракт перенесён 1:1 из
    # `packages/agent-core-v2/src/agent/skill/tools/skill.ts`.
    # Каталог skill'ов и парсинг плейсхолдеров делегированы
    # `SkillCatalog`, который инжекчит реальная инфраструктура skill.
    #
    # См. детальный план портирования в `md-tools/skill.md`.
    class Skill < Tool
      MAX_SKILL_QUERY_DEPTH = 3

      DESCRIPTION = <<-TEXT
        Invoke a registered skill from the current skill listing. BLOCKING REQUIREMENT: when a skill from the listing matches the user's request, you MUST call this tool (not free-form text). Do not re-invoke a skill to repeat work already done: if a `<hcode-skill-loaded>` block for it with the same `args` is already present in the conversation, follow those instructions directly instead of calling the tool again. Do call the tool again when you need the skill with different arguments — the loaded block was expanded with the earlier `args` and will not reflect new inputs.
      TEXT

      # Глобальный инжекченный каталог skill'ов. nil → тул возвращает ошибку.
      @@catalog : SkillCatalog?

      # Глобальная ссылка на Context::Memory для injection. nil → injection
      # silently пропускается.
      @@memory : Context::Memory?

      # Глубина вложенного вызова skill (query depth state). Защита от
      # бесконечной рекурсии.
      @@current_depth : Int32 = 0

      def self.catalog=(c : SkillCatalog?) : Nil
        @@catalog = c
      end

      def self.catalog : SkillCatalog?
        @@catalog
      end

      def self.memory=(m : Context::Memory?) : Nil
        @@memory = m
      end

      def self.memory : Context::Memory?
        @@memory
      end

      def self.current_depth : Int32
        @@current_depth
      end

      def self.current_depth=(v : Int32) : Nil
        @@current_depth = v
      end

      def name : String
        "Skill"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "skill": {
              "type": "string",
              "description": "The exact name of the skill to invoke, spelled as it appears in the current skill listing (e.g. \"commit\", \"pdf\")."
            },
            "args": {
              "type": "string",
              "description": "Optional argument string for the skill, written like a command line (e.g. `-m \"fix bug\"`, `123`, a file path). It is split on whitespace (quotes group a token) and expanded into the skill's placeholders ($NAME, $1, $ARGUMENTS); if the skill body has no placeholders, the whole string is still appended as a trailing `ARGUMENTS:` line. Omit it only when there is nothing to pass."
            }
          },
          "required": ["skill"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        skill_name = input["skill"]?.try(&.to_s) || ""
        raw_args = input["args"]?.try(&.to_s) || ""

        if @@current_depth >= MAX_SKILL_QUERY_DEPTH
          raise NestedSkillTooDeepError.new(skill_name.empty? ? nil : skill_name, @@current_depth)
        end

        catalog = @@catalog
        return ToolResult.error("Skill catalog is not initialized.") if catalog.nil?

        if skill_name.empty?
          return ToolResult.error("Skill \"\" not found in the current skill listing.")
        end

        normalized = skill_name.downcase
        skill = catalog.get_skill(normalized)
        if skill.nil?
          return ToolResult.error("Skill \"#{skill_name}\" not found in the current skill listing.")
        end

        if skill.metadata.disable_model_invocation
          return ToolResult.error("Skill \"#{skill.name}\" can only be triggered by the user (model invocation is disabled).")
        end

        unless inline_skill_type?(skill.metadata.type)
          return ToolResult.error("Skill \"#{skill.name}\" is not an inline skill and cannot be invoked by the model in v1.")
        end

        trigger = @@current_depth > 0 ? "nested-skill" : "model-tool"
        skill_args = raw_args

        skill_content = catalog.render_skill_prompt(skill, skill_args, nil)
        injection_text = render_model_tool_skill_prompt(
          skill_name: skill.name,
          skill_args: skill_args,
          skill_content: skill_content,
          skill_source: skill.source,
          skill_dir: skill.path ? File.dirname(skill.path.not_nil!) : nil,
          trigger: trigger,
        )

        @@memory.try(&.add_injection(injection_text))

        ToolResult.success("Skill \"#{skill.name}\" loaded inline. Follow its instructions.")
      end

      # ------------------------------------------------------------------
      # Validation helpers
      # ------------------------------------------------------------------

      def inline_skill_type?(type : String?) : Bool
        type.nil? || type == "prompt" || type == "inline"
      end

      # ------------------------------------------------------------------
      # Rendering helpers
      # ------------------------------------------------------------------

      def render_model_tool_skill_prompt(skill_name : String,
                                         skill_args : String,
                                         skill_content : String,
                                         skill_source : String?,
                                         skill_dir : String?,
                                         trigger : String) : String
        attrs = render_skill_attributes(
          skill_name: skill_name,
          skill_args: skill_args,
          skill_source: skill_source,
          skill_dir: skill_dir,
          trigger: trigger,
        )

        String.build do |io|
          io << "Skill tool loaded instructions for this request. Follow them.\n"
          io << "<hcode-skill-loaded#{attrs}>\n"
          io << skill_content
          io << "\n</hcode-skill-loaded>"
        end
      end

      def render_skill_attributes(skill_name : String,
                                  skill_args : String,
                                  skill_source : String?,
                                  skill_dir : String?,
                                  trigger : String) : String
        parts = [] of String
        parts << %(name="#{escape_xml(skill_name)}")
        parts << %(trigger="#{escape_xml(trigger)}")
        parts << %(source="#{escape_xml(skill_source)}") if skill_source && !skill_source.empty?
        parts << %(dir="#{escape_xml(skill_dir)}") if skill_dir && !skill_dir.empty?
        parts << %(args="#{escape_xml(skill_args)}")
        parts.map { |p| " " + p }.join
      end

      def escape_xml(value : String?) : String
        return "" if value.nil?
        value.gsub('&', "&amp;")
          .gsub('<', "&lt;")
          .gsub('>', "&gt;")
          .gsub('"', "&quot;")
      end

      # escape_xml_tags — только `<` и `>` (для skill body).
      def escape_xml_tags(value : String) : String
        value.gsub('<', "&lt;").gsub('>', "&gt;")
      end

      def escape_xml_attr(value : String) : String
        value.gsub('&', "&amp;").gsub('"', "&quot;")
      end

      # ------------------------------------------------------------------
      # Args tokenizer (CLI-style: whitespace делит, кавычки группируют).
      # ------------------------------------------------------------------

      def tokenize_args(raw : String) : Array(String)
        tokens = [] of String
        current = ""
        in_single = false
        in_double = false
        has_token = false

        i = 0
        while i < raw.size
          c = raw[i]
          if in_single
            if c == '\''
              in_single = false
            else
              current += c
              has_token = true
            end
          elsif in_double
            if c == '"'
              in_double = false
            else
              current += c
              has_token = true
            end
          elsif c == '\''
            in_single = true
            has_token = true # открыть пустой токен, если кавычки сразу закрылись
          elsif c == '"'
            in_double = true
            has_token = true
          elsif c == ' ' || c == '\t' || c == '\n' || c == '\r'
            if has_token
              tokens << current
              current = ""
              has_token = false
            end
          else
            current += c
            has_token = true
          end
          i += 1
        end

        tokens << current if has_token
        tokens
      end

      # Имена аргументов из metadata.arguments (строка или массив строк).
      # Имена, состоящие только из цифр или пустые, отбрасываются.
      def parse_argument_names(arguments : String? | Array(String)?) : Array(String)
        return [] of String if arguments.nil?
        raw = case arguments
              when String       then arguments.split(/\s+/)
              when Array(String) then arguments
              else
                [] of String
              end
        raw.reject { |name| name.empty? || name.matches?(/^\d+$/) }
      end

      # ------------------------------------------------------------------
      # Render skill body: замена плейсхолдеров.
      # ------------------------------------------------------------------

      def render_skill_prompt(skill : SkillDefinition,
                              raw_args : String,
                              session_id : String?,
                              skill_dir : String?) : String
        body = skill.content
        argument_names = parse_argument_names(skill.metadata.arguments)
        tokens = tokenize_args(raw_args)
        replaced_argument_placeholder = false

        out = String.build do |io|
          i = 0
          while i < body.size
            c = body[i]

            # ${HCODE_SKILL_DIR}
            if body[i, 19]? == "${HCODE_SKILL_DIR}"
              io << (skill_dir || "")
              i += 19
              next
            end

            # ${HCODE_SESSION_ID}
            if body[i, 20]? == "${HCODE_SESSION_ID}"
              io << (session_id || "")
              i += 20
              next
            end

            # $ARGUMENTS[<n>]
            if body[i, 12]? == "$ARGUMENTS["
              close = body.index(']', i + 12)
              if close
                num_str = body[i + 12, close - (i + 12)]
                num = num_str.to_i?
                if num
                  # 1-indexed: $ARGUMENTS[1] = tokens[0]
                  io << (tokens[num - 1]? || "")
                  replaced_argument_placeholder = true
                end
                i = close + 1
                next
              end
            end

            # $<n> (не следует за word char) — 1-indexed positional.
            if c == '$' && (next_ch = body[i + 1]?) && next_ch.ascii_number?
              num = next_ch - '0'
              io << (tokens[num - 1]? || "")
              replaced_argument_placeholder = true
              i += 2
              next
            end

            # $ARGUMENTS (без скобок) — весь raw_args. Должно идти ДО $<name>,
            # иначе «ARGUMENTS» распознаётся как имя.
            if body[i, 11]? == "$ARGUMENTS"
              next_after = body[i + 11]?
              if next_after.nil? || !next_after.ascii_alphanumeric?
                io << escape_xml_tags(raw_args)
                replaced_argument_placeholder = true
                i += 11
                next
              end
            end

            # $<name> (не следует за [, word char)
            if c == '$' && (next_ch = body[i + 1]?) && !next_ch.ascii_letter?
              io << c
              i += 1
              next
            end

            if c == '$' && (next_ch = body[i + 1]?) && next_ch.ascii_letter?
              # extract name
              end_idx = i + 1
              while end_idx < body.size && (body[end_idx].ascii_alphanumeric? || body[end_idx] == '_')
                end_idx += 1
              end
              name = body[i + 1, end_idx - (i + 1)]
              if argument_names.includes?(name)
                idx = argument_names.index(name).not_nil!
                io << escape_xml_tags(tokens[idx]? || "")
                replaced_argument_placeholder = true
              else
                io << "$" << name
              end
              i = end_idx
              next
            end

            io << c
            i += 1
          end
        end

        # Если ни один аргументный плейсхолдер не заменён и есть raw_args →
        # добавить `ARGUMENTS:` строку.
        if !replaced_argument_placeholder && !raw_args.strip.empty?
          out = out + "\n\nARGUMENTS: #{escape_xml_tags(raw_args)}"
        end

        out
      end
    end

    # --------------------------------------------------------------------
    # Контрактные типы
    # --------------------------------------------------------------------

    class NestedSkillTooDeepError < Exception
      getter skill_name : String?
      getter depth : Int32

      def initialize(@skill_name : String?, @depth : Int32)
        name_str = @skill_name ? "\"#{@skill_name}\"" : ""
        super("Nested skill invocation #{name_str} exceeded the maximum depth of #{@depth} — refusing to recurse further.")
      end
    end

    struct SkillMetadata
      property type : String?
      property name : String?
      property description : String?
      property when_to_use : String?
      property arguments : String? | Array(String)?
      property disable_model_invocation : Bool

      def initialize(@type : String? = nil,
                     @name : String? = nil,
                     @description : String? = nil,
                     @when_to_use : String? = nil,
                     @arguments : String? | Array(String)? = nil,
                     @disable_model_invocation : Bool = false)
      end
    end

    struct SkillDefinition
      getter name : String
      getter content : String
      getter metadata : SkillMetadata
      getter path : String?
      getter source : String

      def initialize(@name : String,
                     @content : String,
                     @metadata : SkillMetadata = SkillMetadata.new,
                     @path : String? = nil,
                     @source : String = "project")
      end

      def description : String
        @metadata.description || description_from_body
      end

      private def description_from_body : String
        @content.strip.lines.first?.try(&.strip) || ""
      end

      def when_to_use : String?
        @metadata.when_to_use
      end

      def profiled_bytes : Int64
        @name.profiled_bytes + @content.profiled_bytes + @source.profiled_bytes +
          (@path.try(&.profiled_bytes) || 0_i64)
      end
    end

    abstract class SkillCatalog
      abstract def get_skill(name : String) : SkillDefinition?
      abstract def ready? : Bool
      abstract def render_skill_prompt(skill : SkillDefinition,
                                       args : String,
                                       session_id : String?) : String
    end

    # Простейшая in-memory реализация — список skill с поддержкой
    # плейсхолдеров. Используется в тестах и как fallback в runtime.
    class InMemorySkillCatalog < SkillCatalog
      @skills = {} of String => SkillDefinition

      def initialize(skills : Array(SkillDefinition) = [] of SkillDefinition)
        skills.each { |s| register(s) }
      end

      def register(skill : SkillDefinition) : Nil
        @skills[skill.name.downcase] = skill
      end

      def get_skill(name : String) : SkillDefinition?
        @skills[name.downcase]?
      end

      def ready? : Bool
        true
      end

      def profiled_bytes : Int64
        @skills.values.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @skills.size
      end

      def render_skill_prompt(skill : SkillDefinition,
                              args : String,
                              session_id : String?) : String
        renderer = Skill.new
        skill_dir = skill.path ? File.dirname(skill.path.not_nil!) : nil
        renderer.render_skill_prompt(skill, args, session_id, skill_dir)
      end

      # Listing injected into the system prompt so the model knows which
      # skills exist and when to call them. Mirrors TS `getModelSkillListing`.
      def model_listing : String
        return "" if @skills.empty?
        lines = ["DISREGARD any earlier skill listings. Current available skills:"]
        @skills.values.each do |skill|
          next if skill.metadata.disable_model_invocation
          lines << "- #{skill.name}: #{truncate(skill.description, 80)}"
          if w = skill.when_to_use
            lines << "  When to use: #{w}"
          end
          if p = skill.path
            lines << "  Path: #{p}"
          end
        end
        lines.size == 1 ? "" : lines.join('\n')
      end

      private def truncate(s : String, max : Int32) : String
        return s if s.size <= max
        "#{s[0, max - 3]}..."
      end
    end

    # Filesystem skill discovery: scans the standard skill directories
    # (mirrors TS `skillRoots.ts` + `fileSkillDiscovery.ts`) and parses each
    # `SKILL.md` into a `SkillDefinition`.
    module SkillDiscovery
      USER_BRAND_DIRS   = ["skills"]
      USER_GENERIC_DIRS = [".agents/skills"]
      PROJECT_BRAND_DIRS   = [".hcode/skills"]
      PROJECT_GENERIC_DIRS = [".agents/skills"]

      # Scan both user (home) and project (work_dir) roots, parse SKILL.md
      # files, return deduplicated skills ordered by discovery.
      def self.discover(home : String, work_dir : String) : Array(SkillDefinition)
        roots = [] of {String, String} # {dir, source}
        roots.concat(user_roots(home))
        roots.concat(project_roots(work_dir))

        skills = [] of SkillDefinition
        seen = Set(String).new

        roots.each do |dir, source|
          next unless Dir.exists?(dir)
          walk_skill_dir(dir, source, 0, skills, seen)
        end

        skills
      end

      private def self.user_roots(home : String) : Array({String, String})
        dirs = [] of {String, String}
        USER_BRAND_DIRS.each { |d| dirs << {File.join(home, d), "user"} }
        USER_GENERIC_DIRS.each { |d| dirs << {File.join(home, d), "user"} }
        dirs
      end

      private def self.project_roots(work_dir : String) : Array({String, String})
        project_root = find_project_root(work_dir)
        dirs = [] of {String, String}
        PROJECT_BRAND_DIRS.each { |d| dirs << {File.join(project_root, d), "project"} }
        PROJECT_GENERIC_DIRS.each { |d| dirs << {File.join(project_root, d), "project"} }
        dirs
      end

      # Walk up from `work_dir` to the nearest `.git`, returning that root.
      # Falls back to `work_dir` itself if no git boundary is found, so
      # discovery still scans the given workspace (not the filesystem root).
      private def self.find_project_root(work_dir : String) : String
        start = File.expand_path(work_dir)
        current = start
        loop do
          return current if Dir.exists?(File.join(current, ".git"))
          parent = File.dirname(current)
          return start if parent == current
          current = parent
        end
      end

      private def self.walk_skill_dir(dir : String, source : String, depth : Int32,
                                      skills : Array(SkillDefinition), seen : Set(String)) : Nil
        return if depth > 8
        begin
          entries = Dir.children(dir).sort
        rescue File::Error
          return
        end

        entries.each do |entry|
          path = File.join(dir, entry)
          skill_md = File.join(path, "SKILL.md")

          # Subdirectory with a SKILL.md → directory skill
          if Dir.exists?(path) && File.file?(skill_md)
            parse_and_register(skill_md, entry, source, skills, seen)
          end
        end

        # A SKILL.md directly in the root dir itself
        root_skill = File.join(dir, "SKILL.md")
        if File.file?(root_skill)
          parse_and_register(root_skill, File.basename(dir), source, skills, seen)
        end
      end

      private def self.parse_and_register(skill_md_path : String, dir_name : String,
                                          source : String, skills : Array(SkillDefinition),
                                          seen : Set(String)) : Nil
        return if seen.includes?(skill_md_path)
        begin
          text = File.read(skill_md_path)
        rescue
          return
        end

        begin
          skill = Parser.parse(text, skill_md_path, dir_name, source)
          seen << skill_md_path
          skills << skill
        rescue ex : Exception
          # Skip unparseable skills silently; logged at debug in TS.
        end
      end
    end

    # SKILL.md parser: frontmatter (simple YAML) + body. Mirrors TS `parser.ts`
    # for the subset of fields hcode uses (name, description, type, when-to-use,
    # arguments, disable-model-invocation).
    module Parser
      FENCE = "---"

      def self.parse(text : String, skill_md_path : String, dir_name : String,
                     source : String) : SkillDefinition
        data, body = parse_frontmatter(text)
        metadata = normalize_metadata(data)

        name = metadata.name || dir_name
        content = body.strip

        SkillDefinition.new(
          name: name,
          content: content,
          metadata: metadata,
          path: File.expand_path(skill_md_path),
          source: source,
        )
      end

      private def self.parse_frontmatter(text : String) : {Hash(String, JSON::Any), String}
        lines = text.lines(chomp: true)
        empty = {} of String => JSON::Any
        return {empty, text} unless lines[0]?.try(&.strip) == FENCE

        close_idx = (1...lines.size).find { |i| lines[i].strip == FENCE }
        raise "Missing closing frontmatter fence in SKILL.md" unless close_idx

        yaml_text = lines[1...close_idx].join('\n')
        body = lines[(close_idx + 1)..].join('\n')
        data = parse_simple_yaml(yaml_text)
        {data, body}
      end

      # Minimal YAML parser for flat key: value frontmatter (no nesting,
      # no flow sequences beyond `arguments: [a, b]`). Avoids a YAML shard
      # dependency for this narrow use case.
      private def self.parse_simple_yaml(text : String) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        text.each_line do |raw|
          line = raw.strip
          next if line.empty? || line.starts_with?('#')
          idx = line.index(':')
          next unless idx
          key = line[0...idx].strip
          val = line[(idx + 1)..].strip

          # Handle aliases: when-to-use / when_to_use → whenToUse, etc.
          key = normalize_key(key)

          if val.starts_with?('[') && val.ends_with?(']')
            items = val[1...-1].split(',').map(&.strip.strip('"'))
            arr = items.reject(&.empty?).map { |s| JSON::Any.new(s) }
            result[key] = JSON::Any.new(arr)
          else
            result[key] = JSON::Any.new(val.strip('"'))
          end
        end
        result
      end

      KEY_ALIASES = {
        "when-to-use"            => "when_to_use",
        "disable-model-invocation" => "disable_model_invocation",
      }

      private def self.normalize_key(key : String) : String
        KEY_ALIASES[key]? || key
      end

      private def self.normalize_metadata(data : Hash(String, JSON::Any)) : SkillMetadata
        meta = SkillMetadata.new
        meta.name = data["name"]?.try(&.as_s?)
        meta.description = data["description"]?.try(&.as_s?)
        meta.type = data["type"]?.try(&.as_s?)
        meta.when_to_use = data["when_to_use"]?.try(&.as_s?)
        if a = data["arguments"]?
          meta.arguments = a.as_a?.try(&.map(&.as_s))
        end
        if d = data["disable_model_invocation"]?
          meta.disable_model_invocation = d.as_s? == "true"
        end
        meta
      end
    end
  end
end
