module Hcode
  module Tools
    # AskUserQuestion — структурированный опрос пользователя (1–4 вопроса,
    # 2–4 опции каждый, опционально multi-select, опционально в фоне).
    #
    # Контракт перенесён 1:1 из
    # `packages/agent-core-v2/src/agent/questionTools/tools/ask-user.ts`.
    # Тул отвечает за парсинг, валидацию и рендер результата;
    # фактическое взаимодействие с пользователем делегировано инжекченному
    # `QuestionService`.
    #
    # См. детальный план портирования в `md-tools/ask-user-question.md`.
    class AskUserQuestion < Tool
      MIN_QUESTIONS               = 1
      MAX_QUESTIONS               = 4
      MIN_OPTIONS                 = 2
      MAX_OPTIONS                 = 4
      QUESTION_UNIQUENESS_MESSAGE =
        "Question texts must be unique across questions, and option labels must be unique within each question."
      QUESTION_DISMISSED_MESSAGE =
        "User dismissed the question without answering."
      QUESTION_UNSUPPORTED_FAILURE_MESSAGE =
        "The connected client does not support interactive questions. Do NOT call this tool again. Ask the user directly in your text response instead."
      AUTO_MODE_DENY_MESSAGE =
        "AskUserQuestion is disabled while auto permission mode is active. Make a reasonable decision and continue without asking the user."

      DESCRIPTION = <<-TEXT
        Use this tool when you need to ask the user questions with structured options during execution. This allows you to:
        1. Collect user preferences or requirements before proceeding
        2. Resolve ambiguous or underspecified instructions
        3. Let the user decide between implementation approaches as you work
        4. Present concrete options when multiple valid directions exist

        **When NOT to use:**
        - When you can infer the answer from context — be decisive and proceed
        - Trivial decisions that don't materially affect the outcome

        Overusing this tool interrupts the user's flow. Only use it when the user's input genuinely changes your next action.

        **Usage notes:**
        - Users always have an "Other" option for custom input — don't create one yourself
        - Use multi_select to allow multiple answers to be selected for a question
        - Keep option labels concise (1-5 words), use descriptions for trade-offs and details
        - Each question should have 2-4 meaningful, distinct options
        - Question texts must be unique across the call, and option labels must be unique within each question
        - You can ask 1-4 questions at a time; group related questions to minimize interruptions
        - If you recommend a specific option, list it first and append "(Recommended)" to its label
        - The result is JSON with an `answers` object keyed by question text; each value is the chosen option's label (comma-separated labels for multi_select, or the user's own words if they picked "Other"); if `answers` is empty and a `note` says the user dismissed it, they chose not to answer — do not treat this as selecting the recommended option; decide based on context and do not re-ask the same question
        - Set background=true when you can keep working without the answer. This starts a background question task and returns a task_id immediately. The answer arrives automatically in a later turn — you do not need to poll, sleep, or check on it. Continue with other work; never fabricate or predict the answer.
      TEXT

      # Глобальный инжекченный сервис. nil → тул не работает.
      @@service : QuestionService?

      # Опциональная фоновая служба задач. nil → background=true
      # fallback на foreground.
      @@tasks : AgentTaskService?

      def self.service=(s : QuestionService?) : Nil
        @@service = s
      end

      def self.service : QuestionService?
        @@service
      end

      def self.tasks=(t : AgentTaskService?) : Nil
        @@tasks = t
      end

      def self.tasks : AgentTaskService?
        @@tasks
      end

      def name : String
        "AskUserQuestion"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "questions": {
              "type": "array",
              "minItems": 1,
              "maxItems": 4,
              "description": "The questions to ask the user (1-4 questions).",
              "items": {
                "type": "object",
                "properties": {
                  "question": {
                    "type": "string",
                    "minLength": 1,
                    "description": "A specific, actionable question. End with '?'."
                  },
                  "header": {
                    "type": "string",
                    "description": "Short category tag (max 12 chars, e.g. 'Auth', 'Style')."
                  },
                  "options": {
                    "type": "array",
                    "minItems": 2,
                    "maxItems": 4,
                    "description": "2-4 meaningful, distinct options. Do NOT include an 'Other' option — the system adds one automatically.",
                    "items": {
                      "type": "object",
                      "properties": {
                        "label": {
                          "type": "string",
                          "minLength": 1,
                          "description": "Concise display text (1-5 words). If recommended, append '(Recommended)'."
                        },
                        "description": {
                          "type": "string",
                          "default": "",
                          "description": "Brief explanation of trade-offs or implications."
                        }
                      },
                      "required": ["label"],
                      "additionalProperties": false
                    }
                  },
                  "multi_select": {
                    "type": "boolean",
                    "default": false,
                    "description": "Whether the user can select multiple options."
                  }
                },
                "required": ["question", "options"],
                "additionalProperties": false
              }
            },
            "background": {
              "type": "boolean",
              "default": false,
              "description": "Set true to ask in the background and return immediately with a background task_id; you are notified automatically when the user answers — do not poll with TaskOutput while the question is pending."
            }
          },
          "required": ["questions"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        # Parse + schema-level validation.
        questions = begin
          parse_questions(input)
        rescue ex : SchemaError
          return ToolResult.error(ex.message || "Invalid AskUserQuestion input")
        end

        if err = question_uniqueness_error(questions)
          return ToolResult.error(err)
        end

        background = optional_bool(input, "background")

        service = @@service
        return ToolResult.error(QUESTION_UNSUPPORTED_FAILURE_MESSAGE) if service.nil?

        if background
          tasks = @@tasks
          return execute_question(service, questions) if tasks.nil?
          return execute_in_background(service, tasks, questions)
        end

        execute_question(service, questions)
      end

      # ------------------------------------------------------------------
      # Foreground execution
      # ------------------------------------------------------------------

      private def execute_question(service : QuestionService,
                                   questions : Array(QuestionItem)) : ToolResult
        req = QuestionRequest.new(questions: questions)
        result = service.request(req, nil)
        normalize_result(result)
      rescue ex : AbortError
        raise ex
      rescue ex : NotImplementedError
        ToolResult.error(QUESTION_UNSUPPORTED_FAILURE_MESSAGE)
      rescue ex
        dismissed_result
      end

      # ------------------------------------------------------------------
      # Background execution
      # ------------------------------------------------------------------

      private def execute_in_background(service : QuestionService,
                                        tasks : AgentTaskService,
                                        questions : Array(QuestionItem)) : ToolResult
        description = question_description(questions)
        task_id = begin
          tasks.register_question_task(description, questions.size) do |task_signal|
            req = QuestionRequest.new(questions: questions)
            res = service.request(req, task_signal)
            normalize_result(res).content
          end
        rescue ex
          return ToolResult.error(ex.message || "Failed to start background question task")
        end

        status = tasks.task_status(task_id) || "running"

        ToolResult.success(String.build do |io|
          io << "task_id: #{task_id}\n"
          io << "description: #{description}\n"
          io << "status: #{status}\n"
          io << "automatic_notification: true\n"
          io << "next_step: Continue your current work; the answer will arrive automatically when the user responds.\n"
          io << "next_step: Use TaskOutput with this task_id for a non-blocking status/answer snapshot.\n"
          io << "next_step: Use TaskStop only if the question should be cancelled.\n"
          io << "human_shell_hint: The pending question is also visible in /tasks."
        end)
      end

      # ------------------------------------------------------------------
      # Парсинг / валидация
      # ------------------------------------------------------------------

      private def parse_questions(input : JSON::Any) : Array(QuestionItem)
        raw_list = input["questions"]?.try(&.as_a?) ||
                   raise(SchemaError.new("`questions` must be a non-empty array."))
        raise SchemaError.new("`questions` must contain between #{MIN_QUESTIONS} and #{MAX_QUESTIONS} entries.") if raw_list.size < MIN_QUESTIONS || raw_list.size > MAX_QUESTIONS

        questions = [] of QuestionItem
        raw_list.each do |raw|
          questions << parse_question(raw)
        end
        questions
      end

      private def parse_question(raw : JSON::Any) : QuestionItem
        question = string_field(raw, "question")
        raise SchemaError.new("`questions[].question` must be a non-empty string.") if question.empty?

        opts_raw = raw["options"]?.try(&.as_a?) ||
                   raise(SchemaError.new("`questions[].options` must be a non-empty array."))
        raise SchemaError.new("`questions[].options` must contain between #{MIN_OPTIONS} and #{MAX_OPTIONS} entries.") if opts_raw.size < MIN_OPTIONS || opts_raw.size > MAX_OPTIONS

        options = [] of QuestionOption
        opts_raw.each do |o|
          label = string_field(o, "label")
          raise SchemaError.new("`questions[].options[].label` must be a non-empty string.") if label.empty?
          description = string_field(o, "description", default: "")
          options << QuestionOption.new(label: label, description: description)
        end

        header = string_field(raw, "header", default: "")
        multi_select = bool_field(raw, "multi_select", default: false)

        QuestionItem.new(
          question: question,
          header: header,
          options: options,
          multi_select: multi_select,
        )
      end

      private def string_field(raw : JSON::Any, key : String, default : String? = nil) : String
        v = raw[key]?
        return default || "" if v.nil?
        v.to_s
      end

      private def bool_field(raw : JSON::Any, key : String, default : Bool) : Bool
        v = raw[key]?
        return default if v.nil?
        v.as_bool? || default
      rescue Exception
        default
      end

      private def optional_bool(raw : JSON::Any, key : String) : Bool
        bool_field(raw, key, false)
      end

      # Проверка уникальности вопросов и опций (см. md §3.2).
      def question_uniqueness_error(questions : Array(QuestionItem)) : String?
        seen_questions = {} of String => Nil
        questions.each do |q|
          if seen_questions.has_key?(q.question)
            return "Invalid questions: duplicate question text #{q.question.inspect}. #{QUESTION_UNIQUENESS_MESSAGE} Rephrase the duplicates and call the tool again."
          end
          seen_questions[q.question] = nil

          seen_labels = {} of String => Nil
          q.options.each do |opt|
            if seen_labels.has_key?(opt.label)
              return "Invalid questions: duplicate option label #{opt.label.inspect} in question #{q.question.inspect}. #{QUESTION_UNIQUENESS_MESSAGE} Rephrase the duplicates and call the tool again."
            end
            seen_labels[opt.label] = nil
          end
        end
        nil
      end

      # ------------------------------------------------------------------
      # Рендер результата
      # ------------------------------------------------------------------

      def question_description(questions : Array(QuestionItem)) : String
        first = questions.find { |q| !q.question.strip.empty? }.try(&.question.strip) || "Ask user question"
        return first if questions.size <= 1
        "#{first} (+#{questions.size - 1} more)"
      end

      def normalize_result(result : QuestionResult?) : ToolResult
        if result.nil? || result.empty?
          return dismissed_result
        end

        json = String.build do |io|
          io << "{"
          io << %("answers":{)
          first = true
          result.each do |question, answer|
            io << "," unless first
            first = false
            io << question.inspect
            io << ":"
            io << answer.inspect
          end
          io << "}}"
        end

        ToolResult.success(json)
      end

      def dismissed_result : ToolResult
        ToolResult.success(%({"answers":{},"note":"#{QUESTION_DISMISSED_MESSAGE}"}))
      end
    end

    # --------------------------------------------------------------------
    # Контрактные типы
    # --------------------------------------------------------------------

    class SchemaError < Exception
    end

    struct QuestionOption
      getter label : String
      getter description : String

      def initialize(@label : String, @description : String = "")
      end
    end

    struct QuestionItem
      getter question : String
      getter header : String
      getter options : Array(QuestionOption)
      getter? multi_select : Bool

      def initialize(@question : String,
                     @options : Array(QuestionOption),
                     @header : String = "",
                     @multi_select : Bool = false)
      end
    end

    struct QuestionRequest
      getter turn_id : Int32?
      getter tool_call_id : String?
      getter questions : Array(QuestionItem)

      def initialize(@questions : Array(QuestionItem),
                     @turn_id : Int32? = nil,
                     @tool_call_id : String? = nil)
      end
    end

    # Hash{question text => answer label(s)}. Empty hash → dismissed.
    alias QuestionResult = Hash(String, String)

    abstract class QuestionService
      abstract def request(req : QuestionRequest,
                           signal : ::Hcode::Loop::AbortController?) : QuestionResult?
    end

    # Минимальный контракт фоновой службы задач (используется AskUserQuestion
    # для background-режима). Реальная реализация — `Tools::TaskService` из
    # md-tools/task.md.
    abstract class AgentTaskService
      # Зарегистрировать фоновую задачу, выполняющую `run` с собственным
      # signal. Возвращает task_id.
      abstract def register_question_task(description : String,
                                          question_count : Int32,
                                          &run : ::Hcode::Loop::AbortController? -> String) : String

      # Текущий статус задачи по id (или nil если не найдена).
      abstract def task_status(task_id : String) : String?
    end
  end
end
