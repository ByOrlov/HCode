module Hcode
  module Tools
    # AgentSwarm — параллельный запуск до 128 дочерних субагентов.
    #
    # Контракт перенесён 1:1 из `packages/agent-core-v2/src/agent/swarm/tools/agent-swarm.ts`.
    # Тул отвечает за парсинг, валидацию и XML-рендер результата;
    # фактический запуск субагентов вынесен в инжекченный `SwarmRunner`,
    # чтобы тул оставался чистым и тестопригодным без session-coordinator'а.
    #
    # См. детальный план портирования в `md-tools/swarm.md`.
    class AgentSwarm < Tool
      DESCRIPTION = <<-TEXT
        Launch multiple subagents from one prompt template, existing agent resumes, or both.

        Use AgentSwarm when many subagents should run the same kind of task over different inputs. The placeholder is exactly `{{item}}`. For example, with `prompt_template` set to `Review {{item}} for likely regressions.` and `items` set to `["src/a.ts", "src/b.ts"]`, AgentSwarm launches two new subagents with those two concrete prompts. For a few differently-shaped tasks, make separate `Agent` calls in one message instead.

        Use `resume_agent_ids` to continue subagents that already exist from earlier work, such as ones that failed or timed out: map each agent id to the prompt for that resumed subagent (usually `continue` if no extra information is needed). You may combine `resume_agent_ids` with `items` in the same call to resume existing subagents and launch new ones. Do not duplicate resumed work in `items`.

        Each of these is enforced — a violation is rejected before any subagent starts: provide at least 2 `items` unless you pass `resume_agent_ids`; whenever `items` are present, `prompt_template` is required and must contain `{{item}}`; and the filled-in prompts must be distinct (two items that expand to the same prompt are rejected).

        Use enough subagents to keep the work focused and parallel. AgentSwarm supports up to 128 subagents, and launches are queued automatically, so it is safe to split large tasks into many clear, independent items.

        If `AgentSwarm` is called, that call must be the only tool call in the response.
      TEXT

      DEFAULT_SUBAGENT_TYPE       = "coder"
      PROMPT_TEMPLATE_PLACEHOLDER = "{{item}}"
      MAX_SUBAGENTS               = 128

      NO_RUNNER_ERROR =
        "AgentSwarm is not available: no subagent runtime is registered in this build."

      # Глобальный инжекченный runner. `nil` по умолчанию — тул честно
      # отказывается работать, пока session/swarm coordinator не подключит
      # реальную реализацию. См. `SwarmRunner` и раздел 4 в md-tools/swarm.md.
      @@runner : SwarmRunner?

      def self.runner=(r : SwarmRunner?) : Nil
        @@runner = r
      end

      def self.runner : SwarmRunner?
        @@runner
      end

      def name : String
        "AgentSwarm"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "description": {
              "type": "string",
              "minLength": 1,
              "description": "Short description for the whole swarm."
            },
            "subagent_type": {
              "type": "string",
              "minLength": 1,
              "description": "Subagent type used for every new subagent spawned from items; defaults to coder when omitted. Resumed subagents always keep their original type, so passing subagent_type together with resume_agent_ids is allowed — it only affects the item-based spawns."
            },
            "prompt_template": {
              "type": "string",
              "minLength": 1,
              "description": "Prompt template for each subagent. The {{item}} placeholder is replaced with each item value."
            },
            "items": {
              "type": "array",
              "items": { "type": "string", "minLength": 1 },
              "maxItems": 128,
              "description": "Values used to fill {{item}}. Each item launches one new subagent."
            },
            "resume_agent_ids": {
              "type": "object",
              "additionalProperties": { "type": "string", "minLength": 1 },
              "description": "Map of existing subagent agent_id to the prompt used to resume that subagent. These resumed subagents are launched before new item-based subagents."
            }
          },
          "required": ["description"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        args = parse_input(input)

        begin
          specs = build_specs(args)
        rescue ex : ArgumentError
          return ToolResult.error(ex.message || "Invalid AgentSwarm input")
        end

        runner = @@runner
        return ToolResult.error(NO_RUNNER_ERROR) if runner.nil?

        results = run_specs(specs, args, runner)
        ToolResult.success(render_results(results))
      rescue ex
        ToolResult.error(ex.message || ex.to_s)
      end

      # ------------------------------------------------------------------
      # Парсинг входа
      # ------------------------------------------------------------------

      private def parse_input(raw : JSON::Any) : AgentSwarmInput
        description = required_string(raw, "description")
        subagent_type = optional_trimmed(raw, "subagent_type")
        prompt_template = optional_trimmed(raw, "prompt_template")
        items = optional_string_array(raw, "items")
        resume = optional_string_map(raw, "resume_agent_ids")
        AgentSwarmInput.new(
          description: description,
          subagent_type: subagent_type,
          prompt_template: prompt_template,
          items: items,
          resume_agent_ids: resume,
        )
      end

      private def required_string(raw : JSON::Any, key : String) : String
        v = raw[key]?
        s = v.try(&.to_s) || ""
        s = s.strip
        raise ArgumentError.new("AgentSwarm requires `#{key}` to be a non-empty string.") if s.empty?
        s
      end

      private def optional_trimmed(raw : JSON::Any, key : String) : String?
        v = raw[key]?
        return nil if v.nil?
        s = v.to_s.strip
        s.empty? ? nil : s
      end

      private def optional_string_array(raw : JSON::Any, key : String) : Array(String)?
        v = raw[key]?
        return nil if v.nil?
        arr = v.as_a
        out = [] of String
        arr.each do |item|
          s = item.to_s.strip
          raise ArgumentError.new("`#{key}` entries must be non-empty strings.") if s.empty?
          out << s
        end
        out
      end

      private def optional_string_map(raw : JSON::Any, key : String) : Hash(String, String)
        v = raw[key]?
        return {} of String => String if v.nil?
        obj = v.as_h
        out = {} of String => String
        obj.each do |k, val|
          ks = k.to_s.strip
          vs = val.to_s.strip
          raise ArgumentError.new("`#{key}` keys must be non-empty strings.") if ks.empty?
          raise ArgumentError.new("`#{key}` values must be non-empty strings.") if vs.empty?
          out[ks] = vs
        end
        out
      end

      # ------------------------------------------------------------------
      # Построение спецификаций — `createAgentSwarmSpecs` в JS
      # ------------------------------------------------------------------

      def build_specs(args : AgentSwarmInput) : Array(AgentSwarmSpec)
        items = (args.items || [] of String).dup
        resume = args.resume_agent_ids || {} of String => String
        item_count = items.size
        resume_count = resume.size
        total = item_count + resume_count

        unless has_minimum_inputs?(item_count, resume_count)
          raise ArgumentError.new(
            "AgentSwarm requires at least 2 items unless resume_agent_ids is provided.")
        end

        if total > MAX_SUBAGENTS
          raise ArgumentError.new(
            "AgentSwarm supports at most #{MAX_SUBAGENTS} subagents.")
        end

        prompt_template = args.prompt_template
        if item_count > 0 && prompt_template.nil?
          raise ArgumentError.new("prompt_template is required when items are provided.")
        end
        if !prompt_template.nil? && !prompt_template.includes?(PROMPT_TEMPLATE_PLACEHOLDER)
          raise ArgumentError.new(
            "prompt_template must include the #{PROMPT_TEMPLATE_PLACEHOLDER} placeholder.")
        end

        specs = [] of AgentSwarmSpec

        # Resume-спеки идут первыми; индексация сквозная с 1 (как в JS).
        resume.each do |agent_id, prompt|
          specs << ResumeSpec.new(
            index: specs.size + 1,
            agent_id: agent_id,
            prompt: prompt,
            item: fetch_resume_item(agent_id),
          )
        end

        if item_count > 0
          template = prompt_template.not_nil!
          seen = {} of String => Int32
          items.each_with_index do |item, idx|
            prompt = template.split(PROMPT_TEMPLATE_PLACEHOLDER).join(item)
            if seen[prompt]?
              raise ArgumentError.new(
                "Duplicate subagent prompts from items #{seen[prompt]} and #{idx + 1}. " \
                "AgentSwarm requires distinct subagents.")
            end
            seen[prompt] = idx + 1
            specs << SpawnSpec.new(
              index: specs.size + 1,
              item: item,
              prompt: prompt,
            )
          end
        end

        specs
      end

      # Поддержка v1-стиля: lookup сохранённого item-лейбла для resumed агента.
      # Пока coordinator'а нет — всегда nil. Точка расширения позже.
      private def fetch_resume_item(agent_id : String) : String?
        runner = @@runner
        return nil if runner.nil?
        runner.resume_item?(agent_id)
      end

      def has_minimum_inputs?(item_count : Int32, resume_count : Int32) : Bool
        resume_count > 0 || item_count >= 2
      end

      def child_description(swarm_description : String, index : Int32, profile_name : String) : String
        "#{swarm_description} ##{index} (#{profile_name})"
      end

      # ------------------------------------------------------------------
      # Запуск specs через инжекченный runner
      # ------------------------------------------------------------------

      private def run_specs(specs : Array(AgentSwarmSpec),
                            args : AgentSwarmInput,
                            runner : SwarmRunner) : Array(SwarmRunResult)
        profile = args.subagent_type || DEFAULT_SUBAGENT_TYPE
        timeout_ms = runner.timeout_ms
        results = Array(SwarmRunResult).new(specs.size)

        results_channel = Channel(SwarmRunResult?).new(specs.size)

        specs.each do |spec|
          spawn do
            value = begin
              run_one(spec, args, profile, timeout_ms, runner)
            rescue ex
              SwarmRunResult.new(
                spec: spec,
                agent_id: nil,
                status: SwarmStatus::Failed,
                state: nil,
                result: nil,
                error: ex.message || ex.to_s,
              )
            end
            results_channel.send(value)
          rescue ex
            results_channel.send(nil)
          end
        end

        specs.size.times do
          r = results_channel.receive
          results << r unless r.nil?
        end

        # Восстановить порядок: отсортировать по spec.index (1-...)
        results.sort_by! { |r| r.spec.index }
      end

      private def run_one(spec : AgentSwarmSpec,
                          args : AgentSwarmInput,
                          profile : String,
                          timeout_ms : Int32?,
                          runner : SwarmRunner) : SwarmRunResult
        description_name = spec.is_a?(ResumeSpec) ? "resume" : profile
        ctx = SwarmRunContext.new(
          parent_description: args.description,
          profile_name: spec.is_a?(ResumeSpec) ? "subagent" : profile,
          description: child_description(args.description, spec.index, description_name),
          swarm_index: spec.index,
          timeout_ms: timeout_ms,
          tool_call_id: @tool_call_id,
        )
        runner.call(spec, ctx)
      end

      # ------------------------------------------------------------------
      # Рендер XML — `renderSwarmResults` в JS
      # ------------------------------------------------------------------

      def render_results(results : Array(SwarmRunResult)) : String
        completed = results.count { |r| r.status.completed? }
        failed = results.count { |r| r.status.failed? }
        aborted = results.count { |r| r.status.aborted? }
        should_render_resume_hint =
          results.any? { |r| !r.status.completed? } &&
            results.any? { |r| !r.agent_id.nil? }

        lines = [] of String
        lines << "<agent_swarm_result>"
        lines << "<summary>#{render_summary(completed, failed, aborted)}</summary>"

        if should_render_resume_hint
          lines << "<resume_hint>Call AgentSwarm with resume_agent_ids using the agent_id values in this result to continue unfinished work.</resume_hint>"
        end

        results.each do |r|
          lines << render_subagent(r)
        end

        lines << "</agent_swarm_result>"
        lines.join("\n")
      end

      private def render_subagent(r : SwarmRunResult) : String
        agent_id_attr = r.agent_id.nil? ? "" : %( agent_id="#{r.agent_id}")
        mode_attr = r.spec.is_a?(ResumeSpec) ? %( mode="resume") : ""
        item_value = r.spec.item
        item_attr = item_value.nil? ? "" : %( item="#{escape_xml_attribute(item_value)}")
        state_attr = r.state.nil? ? "" : %( state="#{r.state}")
        body = r.status.completed? ? (r.result || "") : (r.error || "unknown error")
        %(<subagent#{mode_attr}#{agent_id_attr}#{item_attr}#{state_attr} outcome="#{r.status.to_wire}">#{body}</subagent>)
      end

      def render_summary(completed : Int32, failed : Int32, aborted : Int32 = 0) : String
        parts = [] of String
        parts << "completed: #{completed}" if completed > 0
        parts << "failed: #{failed}" if failed > 0
        parts << "aborted: #{aborted}" if aborted > 0
        parts.join(", ")
      end

      def escape_xml_attribute(value : String) : String
        value.gsub('&', "&amp;")
          .gsub('"', "&quot;")
          .gsub('<', "&lt;")
          .gsub('>', "&gt;")
      end
    end

    # --------------------------------------------------------------------
    # Типы данных контракта
    # --------------------------------------------------------------------

    struct AgentSwarmInput
      getter description : String
      getter subagent_type : String?
      getter prompt_template : String?
      getter items : Array(String)?
      getter resume_agent_ids : Hash(String, String)?

      def initialize(@description : String,
                     @subagent_type : String? = nil,
                     @prompt_template : String? = nil,
                     @items : Array(String)? = nil,
                     @resume_agent_ids : Hash(String, String)? = nil)
      end
    end

    abstract struct AgentSwarmSpec
      getter index : Int32
      getter prompt : String
      property item : String?

      def initialize(@index : Int32, @prompt : String, @item : String? = nil)
      end

      abstract def kind : String
    end

    struct SpawnSpec < AgentSwarmSpec
      def kind : String
        "spawn"
      end
    end

    struct ResumeSpec < AgentSwarmSpec
      getter agent_id : String

      def initialize(index : Int32, @agent_id : String, prompt : String, item : String? = nil)
        super(index, prompt, item)
      end

      def kind : String
        "resume"
      end
    end

    enum SwarmStatus
      Completed
      Failed
      Aborted

      def completed? : Bool
        self == Completed
      end

      def failed? : Bool
        self == Failed
      end

      def aborted? : Bool
        self == Aborted
      end

      # Wire-строковое представление, совпадающее с JS
      # (`'completed' | 'failed' | 'aborted'`).
      def to_wire : String
        case self
        in Completed then "completed"
        in Failed    then "failed"
        in Aborted   then "aborted"
        end
      end
    end

    struct SwarmRunResult
      getter spec : AgentSwarmSpec
      getter agent_id : String?
      getter status : SwarmStatus
      getter state : String?
      getter result : String?
      getter error : String?

      def initialize(@spec : AgentSwarmSpec,
                     @status : SwarmStatus,
                     @agent_id : String? = nil,
                     @state : String? = nil,
                     @result : String? = nil,
                     @error : String? = nil)
      end
    end

    struct SwarmRunContext
      getter parent_description : String
      getter profile_name : String
      getter description : String
      getter swarm_index : Int32
      getter timeout_ms : Int32?
      getter tool_call_id : String

      def initialize(@parent_description : String,
                     @profile_name : String,
                     @description : String,
                     @swarm_index : Int32,
                     @timeout_ms : Int32? = nil,
                     @tool_call_id : String = "")
      end
    end

    # Контракт инжекченного runner'а. Эквивалент JS-связки
    # `ISessionSwarmService.run` + `IAgentSwarmService.enter`.
    #
    # Реализация отвечает за:
    #   * запуск одного субагента по spec + ctx;
    #   * возврат `SwarmRunResult` (включая agent_id для resume);
    #   * обработку timeout/abort внутри себя;
    #   * lookup сохранённого swarm-item лейбла для resume (v1-parity).
    module SwarmRunner
      # Optional callback to emit subagent lifecycle events to the parent's
      # event loop. Set by the session before the tool runs so the TUI can
      # render live per-agent progress.
      property event_sink : (Loop::Event ->)?

      abstract def call(spec : AgentSwarmSpec, ctx : SwarmRunContext) : SwarmRunResult

      def emit(event : Loop::Event) : Nil
        @event_sink.try(&.call(event))
      end

      # Опциональный lookup сохранённого item-лейбла для resumed агента.
      # По умолчанию nil — позволяет повторить контракт JS `getSwarmItem`.
      def resume_item?(agent_id : String) : String?
        nil
      end

      # Глобальный timeout для каждого субагента. nil = без таймаута
      # (по умолчанию — пусть coordinator сам решает).
      def timeout_ms : Int32?
        nil
      end
    end
  end
end
