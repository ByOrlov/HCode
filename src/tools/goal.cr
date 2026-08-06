module Hcode
  module Tools
    # Goal tools — управление durable целью агента.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/agent/goal/tools/`.
    #
    # Все 4 тула регистрируются только для main agent'а.
    #
    # См. детальный план портирования в `md-tools/goal.md`.
    module Goal
      MAX_OBJECTIVE_LENGTH            =       4000
      MAX_COMPLETION_CRITERION_LENGTH =       4000
      MIN_REASONABLE_TIME_BUDGET_MS   =      1_000
      MAX_REASONABLE_TIME_BUDGET_MS   = 86_400_000

      BUDGET_UNITS = ["turns", "tokens", "milliseconds", "seconds", "minutes", "hours"]

      def self.service=(s : GoalService?)
        @@service = s
      end

      def self.service : GoalService?
        @@service
      end

      @@service : GoalService?

      # Hook для `ToolResult` с дополнительным флагом stop_turn. Пока не
      # реализован в `Tools::ToolResult` — отдаём plain ToolResult.
    end

    # --------------------------------------------------------------------
    # Состояние цели (модели)
    # --------------------------------------------------------------------

    enum GoalStatus
      Active
      Paused
      Blocked
      Complete

      def to_wire : String
        case self
        in Active   then "active"
        in Paused   then "paused"
        in Blocked  then "blocked"
        in Complete then "complete"
        end
      end

      # Placeholder for stale-check; always false until tool-target infra exists.
      def goal_id_changed?(snapshot : GoalSnapshot) : Bool
        false
      end
    end

    struct GoalBudgetLimits
      property token_budget : Int32?
      property turn_budget : Int32?
      property wall_clock_budget_ms : Int64?

      def initialize(@token_budget : Int32? = nil,
                     @turn_budget : Int32? = nil,
                     @wall_clock_budget_ms : Int64? = nil)
      end

      def self.empty : GoalBudgetLimits
        new
      end

      def any? : Bool
        !@token_budget.nil? || !@turn_budget.nil? || !@wall_clock_budget_ms.nil?
      end
    end

    struct GoalBudgetReport
      property token_budget : Int32?
      property turn_budget : Int32?
      property wall_clock_budget_ms : Int64?
      property remaining_tokens : Int32?
      property remaining_turns : Int32?
      property remaining_wall_clock_ms : Int64?
      property? token_budget_reached : Bool
      property? turn_budget_reached : Bool
      property? wall_clock_budget_reached : Bool
      property? over_budget : Bool

      def initialize(@token_budget : Int32? = nil,
                     @turn_budget : Int32? = nil,
                     @wall_clock_budget_ms : Int64? = nil,
                     @remaining_tokens : Int32? = nil,
                     @remaining_turns : Int32? = nil,
                     @remaining_wall_clock_ms : Int64? = nil,
                     @token_budget_reached : Bool = false,
                     @turn_budget_reached : Bool = false,
                     @wall_clock_budget_reached : Bool = false,
                     @over_budget : Bool = false)
      end
    end

    struct GoalSnapshot
      getter goal_id : String
      getter objective : String
      getter completion_criterion : String?
      getter status : GoalStatus
      getter turns_used : Int32
      getter tokens_used : Int32
      getter wall_clock_ms : Int64
      getter budget_limits : GoalBudgetLimits
      getter wall_clock_resumed_at : Int64?
      getter budget : GoalBudgetReport
      getter terminal_reason : String?

      def initialize(@goal_id : String,
                     @objective : String,
                     @status : GoalStatus,
                     @turns_used : Int32 = 0,
                     @tokens_used : Int32 = 0,
                     @wall_clock_ms : Int64 = 0,
                     @completion_criterion : String? = nil,
                     @budget_limits : GoalBudgetLimits = GoalBudgetLimits.empty,
                     @wall_clock_resumed_at : Int64? = nil,
                     @terminal_reason : String? = nil)
        @budget = compute_budget_report
      end

      # Live wall-clock: accumulated total + in-flight active interval.
      def live_wall_clock_ms(now : Int64 = Time.utc.to_unix_ms) : Int64
        if status.active? && (anchor = @wall_clock_resumed_at)
          @wall_clock_ms + Math.max(0_i64, now - anchor)
        else
          @wall_clock_ms
        end
      end

      private def compute_budget_report(now : Int64 = Time.utc.to_unix_ms) : GoalBudgetReport
        limits = @budget_limits
        wc = live_wall_clock_ms(now)

        token_reached = !(tb = limits.token_budget).nil? && @tokens_used >= tb
        turn_reached = !(tb2 = limits.turn_budget).nil? && @turns_used >= tb2
        wc_reached = !(wcb = limits.wall_clock_budget_ms).nil? && wc >= wcb

        GoalBudgetReport.new(
          token_budget: limits.token_budget,
          turn_budget: limits.turn_budget,
          wall_clock_budget_ms: limits.wall_clock_budget_ms,
          remaining_tokens: (tb3 = limits.token_budget).nil? ? nil : Math.max(0, tb3 - @tokens_used),
          remaining_turns: (tb4 = limits.turn_budget).nil? ? nil : Math.max(0, tb4 - @turns_used),
          remaining_wall_clock_ms: (wcb2 = limits.wall_clock_budget_ms).nil? ? nil : Math.max(0_i64, wcb2 - wc),
          token_budget_reached: token_reached,
          turn_budget_reached: turn_reached,
          wall_clock_budget_reached: wc_reached,
          over_budget: token_reached || turn_reached || wc_reached,
        )
      end
    end

    # Input structs
    struct CreateGoalInput
      getter objective : String
      getter completion_criterion : String?
      property? replace : Bool

      def initialize(@objective : String,
                     @completion_criterion : String? = nil,
                     @replace : Bool = false)
      end
    end

    struct GoalReasonInput
      property reason : String?

      def initialize(@reason : String? = nil)
      end
    end

    struct ResumeGoalInput
      property reason : String?
      property? continue_if_paused : Bool = false
      property? continue_if_blocked : Bool = false

      def initialize(@reason : String? = nil,
                     @continue_if_paused : Bool = false,
                     @continue_if_blocked : Bool = false)
      end
    end

    struct BudgetInput
      getter budget_limits : GoalBudgetLimits

      def initialize(@budget_limits : GoalBudgetLimits)
      end
    end

    abstract class GoalService
      abstract def get_goal : GoalSnapshot?
      abstract def is_goal_tool_target?(turn_id : Int32?, goal_id : String?) : Bool
      abstract def create_goal(input : CreateGoalInput, actor : String = "model") : GoalSnapshot
      abstract def pause_goal(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot
      abstract def resume_goal(input : ResumeGoalInput? = nil, actor : String = "model") : GoalSnapshot
      abstract def cancel_goal(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot
      abstract def set_budget_limits(input : BudgetInput, actor : String = "model") : GoalSnapshot
      abstract def mark_complete(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot?
      abstract def mark_blocked(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot?

      # Драйвер: учёт хода (no-op вне active). Возвращает обновлённый snapshot
      # или nil, если цель отсутствует или не active.
      abstract def increment_turn : GoalSnapshot?
      abstract def record_token_usage(delta : Int32) : GoalSnapshot?
      abstract def pause_on_interrupt(reason : String = "Paused after interruption") : GoalSnapshot?
      abstract def pause_active_goal(reason : String = "Paused after runtime stop", actor : String = "runtime") : GoalSnapshot?
    end

    # In-memory реализация GoalService. Хранит текущую цель как GoalSnapshot
    # с актуальными budget_limits и wall-clock интервалами.
    class AgentGoalService < GoalService
      @goal : GoalSnapshot?

      def initialize
        @goal = nil
      end

      def get_goal : GoalSnapshot?
        @goal
      end

      def is_goal_tool_target?(turn_id : Int32?, goal_id : String?) : Bool
        true
      end

      def create_goal(input : CreateGoalInput, actor : String = "model") : GoalSnapshot
        objective = input.objective.strip
        raise GoalError.new("goal.objective_empty") if objective.empty?
        if objective.size > Goal::MAX_OBJECTIVE_LENGTH
          raise GoalError.new("goal.objective_too_long")
        end

        unless input.replace?
          unless @goal.nil?
            raise GoalError.new("goal.already_exists")
          end
        end

        completion = normalize_completion_criterion(input.completion_criterion)

        snapshot = GoalSnapshot.new(
          goal_id: Random::Secure.hex(8),
          objective: objective,
          status: GoalStatus::Active,
          completion_criterion: completion,
          wall_clock_resumed_at: Time.utc.to_unix_ms,
        )
        @goal = snapshot
        snapshot
      end

      def pause_goal(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot
        current = @goal
        raise GoalError.new("goal.no_active_goal") if current.nil?
        raise GoalError.new("goal.not_active") unless current.status.active?
        reason = input.try(&.reason)
        @goal = transition(current, GoalStatus::Paused, terminal_reason: reason)
        @goal.not_nil!
      end

      def resume_goal(input : ResumeGoalInput? = nil, actor : String = "model") : GoalSnapshot
        current = @goal
        raise GoalError.new("goal.no_current_goal") if current.nil?
        unless current.status.paused? || current.status.blocked?
          raise GoalError.new("goal.not_paused_or_blocked")
        end
        @goal = transition(current, GoalStatus::Active, terminal_reason: nil)
        @goal.not_nil!
      end

      def cancel_goal(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot
        current = @goal
        raise GoalError.new("goal.no_current_goal") if current.nil?
        reason = input.try(&.reason) || "cancelled"
        cancelled = transition(current, GoalStatus::Complete, terminal_reason: reason)
        @goal = nil
        cancelled
      end

      def set_budget_limits(input : BudgetInput, actor : String = "model") : GoalSnapshot
        current = @goal
        raise GoalError.new("goal.no_current_goal") if current.nil?
        merged = GoalBudgetLimits.new(
          token_budget: input.budget_limits.token_budget || current.budget_limits.token_budget,
          turn_budget: input.budget_limits.turn_budget || current.budget_limits.turn_budget,
          wall_clock_budget_ms: input.budget_limits.wall_clock_budget_ms || current.budget_limits.wall_clock_budget_ms,
        )
        @goal = rebuild(current, budget_limits: merged)
        @goal.not_nil!
      end

      def mark_complete(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot?
        current = @goal
        return nil if current.nil?
        return nil unless current.status.active?
        reason = input.try(&.reason)
        completed = transition(current, GoalStatus::Complete, terminal_reason: reason)
        @goal = nil
        completed
      end

      def mark_blocked(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot?
        current = @goal
        return nil if current.nil?
        return nil unless current.status.active?
        reason = input.try(&.reason)
        @goal = transition(current, GoalStatus::Blocked, terminal_reason: reason)
        @goal
      end

      # --- Драйвер: учёт хода (no-op вне active) --------------------------

      def increment_turn : GoalSnapshot?
        current = @goal
        return nil if current.nil?
        return nil unless current.status.active?
        @goal = rebuild(current, turns_used: current.turns_used + 1)
        @goal
      end

      def record_token_usage(delta : Int32) : GoalSnapshot?
        current = @goal
        return nil if current.nil?
        return nil unless current.status.active?
        d = delta < 0 ? 0 : delta
        @goal = rebuild(current, tokens_used: current.tokens_used + d)
        @goal
      end

      def pause_on_interrupt(reason : String = "Paused after interruption") : GoalSnapshot?
        pause_active_goal(reason, "user")
      end

      def pause_active_goal(reason : String = "Paused after runtime stop", actor : String = "runtime") : GoalSnapshot?
        current = @goal
        return nil if current.nil?
        return nil unless current.status.active?
        @goal = transition(current, GoalStatus::Paused, terminal_reason: reason)
        @goal
      end

      # ----------------------------------------------------------------

      private def normalize_completion_criterion(value : String?) : String?
        return nil if value.nil?
        trimmed = value.strip
        return nil if trimmed.empty?
        trimmed[0, Math.min(trimmed.size, Goal::MAX_COMPLETION_CRITERION_LENGTH)]
      end

      # Transition to a new status, folding the live wall-clock interval into
      # the accumulated total when leaving `active`, and anchoring a fresh
      # interval when entering it.
      private def transition(snapshot : GoalSnapshot, status : GoalStatus,
                             terminal_reason : String? = nil) : GoalSnapshot
        now = Time.utc.to_unix_ms
        wc = snapshot.wall_clock_ms
        resumed = snapshot.wall_clock_resumed_at

        if snapshot.status.active? && (anchor = resumed)
          wc += Math.max(0_i64, now - anchor)
          resumed = nil
        end
        resumed = now if status.active?

        GoalSnapshot.new(
          goal_id: snapshot.goal_id,
          objective: snapshot.objective,
          status: status,
          turns_used: snapshot.turns_used,
          tokens_used: snapshot.tokens_used,
          wall_clock_ms: wc,
          completion_criterion: snapshot.completion_criterion,
          budget_limits: snapshot.budget_limits,
          wall_clock_resumed_at: resumed,
          terminal_reason: terminal_reason,
        )
      end

      # Rebuild snapshot with field overrides (keeps everything else,
      # recomputes budget report).
      private def rebuild(snapshot : GoalSnapshot, *,
                          turns_used : Int32? = nil,
                          tokens_used : Int32? = nil,
                          budget_limits : GoalBudgetLimits? = nil) : GoalSnapshot
        GoalSnapshot.new(
          goal_id: snapshot.goal_id,
          objective: snapshot.objective,
          status: snapshot.status,
          turns_used: turns_used || snapshot.turns_used,
          tokens_used: tokens_used || snapshot.tokens_used,
          wall_clock_ms: snapshot.wall_clock_ms,
          completion_criterion: snapshot.completion_criterion,
          budget_limits: budget_limits || snapshot.budget_limits,
          wall_clock_resumed_at: snapshot.wall_clock_resumed_at,
          terminal_reason: snapshot.terminal_reason,
        )
      end
    end

    class GoalError < Exception
    end

    # --------------------------------------------------------------------
    # Tools
    # --------------------------------------------------------------------

    class CreateGoal < Tool
      DESCRIPTION = <<-TEXT
        Create a durable, structured goal that the runtime will pursue across multiple turns.

        Call `CreateGoal` only when:

        - the user explicitly asks you to start a goal or work autonomously toward an outcome, or
        - a host goal-intake prompt asks you to create one.

        Do NOT create a goal for greetings, ordinary questions, or vague requests that lack a
        verifiable completion condition. A goal needs a checkable end state.

        When the request is vague, ask the user for the missing completion criterion before creating
        the goal. If the user clearly insists after you warn them that the wording is vague or risky,
        respect that and create the goal.

        Include a `completionCriterion` when the user provides one, or when it can be stated without
        inventing new requirements. Keep `objective` concise; reference long task descriptions by file
        path rather than pasting them.

        Creating a goal fails if one already exists, so use `replace: true` only when the user explicitly
        wants to abandon the current goal and start a new one.
      TEXT

      def name : String
        "CreateGoal"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "objective": {
              "type": "string",
              "minLength": 1,
              "description": "The objective to pursue. Must have a verifiable end state."
            },
            "completionCriterion": {
              "type": "string",
              "description": "How to verify the goal is complete. Include when the user provides one."
            },
            "replace": {
              "type": "boolean",
              "description": "Replace an existing active, paused, or blocked goal instead of failing."
            }
          },
          "required": ["objective"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        objective = input["objective"]?.try(&.to_s) || ""
        completion = input["completionCriterion"]?.try(&.to_s)
        replace = input["replace"]?.try(&.as_bool?) || false

        service = Goal.service
        return ToolResult.error("Goal service is not initialized.") if service.nil?

        # Захват старого goal_id для stale-check.
        goal_at_resolution = service.get_goal

        begin
          snapshot = service.create_goal(
            CreateGoalInput.new(objective: objective, completion_criterion: completion, replace: replace),
            "model"
          )
        rescue ex : GoalError
          return map_goal_error(ex)
        rescue ex
          return ToolResult.error(ex.message || "Failed to create goal.")
        end

        # Stale-check: goal_id сменился после resolution и не является tool-target.
        if goal_at_resolution &&
           goal_at_resolution.goal_id != snapshot.goal_id &&
           !service.is_goal_tool_target?(nil, goal_at_resolution.goal_id)
          return ToolResult.success("Goal not created: the current goal changed.")
        end

        ToolResult.success(snapshot_for_model(snapshot))
      end

      private def map_goal_error(ex : GoalError) : ToolResult
        case ex.message
        when "goal.objective_empty"
          ToolResult.error("Goal objective must not be empty.")
        when "goal.objective_too_long"
          ToolResult.error("Goal objective exceeds the maximum length of #{Goal::MAX_OBJECTIVE_LENGTH} characters.")
        when "goal.already_exists"
          ToolResult.error("A goal already exists. Pass `replace: true` to abandon it and start a new one.")
        else
          ToolResult.error(ex.message || "Failed to create goal.")
        end
      end

      def snapshot_for_model(snapshot : GoalSnapshot) : String
        build_json(snapshot)
      end

      def build_json(snapshot : GoalSnapshot) : String
        String.build do |io|
          io << "{\n"
          io << "  \"goal\": {\n"
          io << "    \"objective\": " << snapshot.objective.to_json << ",\n"
          if cc = snapshot.completion_criterion
            io << "    \"completionCriterion\": " << cc.to_json << ",\n"
          else
            io << "    \"completionCriterion\": null,\n"
          end
          io << "    \"status\": \"" << snapshot.status.to_wire << "\",\n"
          io << "    \"turnsUsed\": " << snapshot.turns_used << ",\n"
          io << "    \"tokensUsed\": " << snapshot.tokens_used << ",\n"
          io << "    \"wallClockMs\": " << snapshot.live_wall_clock_ms << ",\n"
          io << "    \"budget\": " << budget_json(snapshot.budget) << ",\n"
          if tr = snapshot.terminal_reason
            io << "    \"terminalReason\": " << tr.to_json << "\n"
          else
            io << "    \"terminalReason\": null\n"
          end
          io << "  }\n"
          io << "}"
        end
      end

      private def budget_json(report : GoalBudgetReport) : String
        String.build do |io|
          io << "{ "
          parts = [] of String
          parts << "\"tokenBudget\": #{report.token_budget.nil? ? "null" : report.token_budget}"
          parts << "\"turnBudget\": #{report.turn_budget.nil? ? "null" : report.turn_budget}"
          parts << "\"wallClockBudgetMs\": #{report.wall_clock_budget_ms.nil? ? "null" : report.wall_clock_budget_ms}"
          parts << "\"remainingTokens\": #{report.remaining_tokens.nil? ? "null" : report.remaining_tokens}"
          parts << "\"remainingTurns\": #{report.remaining_turns.nil? ? "null" : report.remaining_turns}"
          parts << "\"remainingWallClockMs\": #{report.remaining_wall_clock_ms.nil? ? "null" : report.remaining_wall_clock_ms}"
          parts << "\"tokenBudgetReached\": #{report.token_budget_reached?}"
          parts << "\"turnBudgetReached\": #{report.turn_budget_reached?}"
          parts << "\"wallClockBudgetReached\": #{report.wall_clock_budget_reached?}"
          parts << "\"overBudget\": #{report.over_budget?}"
          io << parts.join(", ")
          io << " }"
        end
      end
    end

    class GetGoal < Tool
      DESCRIPTION = <<-TEXT
        Read the current goal: its objective, completion criterion, status, and budgets (turns, tokens,
        time, and how much of each remains). When the goal has stopped, it also reports the terminal reason.

        Use `GetGoal` before deciding whether to continue working, report completion, report a blocker,
        or respect a pause. It returns `{ "goal": null }` when there is no current goal.
      TEXT

      def name : String
        "GetGoal"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Goal.service
        return ToolResult.error("Goal service is not initialized.") if service.nil?

        snapshot = service.get_goal
        if snapshot.nil?
          return ToolResult.success("{\n  \"goal\": null\n}")
        end

        ToolResult.success(CreateGoal.new.build_json(snapshot))
      end
    end

    class UpdateGoal < Tool
      DESCRIPTION = <<-TEXT
        Update the lifecycle status of the current goal.

        Use `active` to resume work after a pause or block. Use `complete` to mark the goal as done —
        after that, write a concise final message for the user. Use `blocked` for impossible, unsafe,
        or contradictory objectives, or after the same non-terminal blocking condition repeats for at
        least 3 consecutive goal turns.
      TEXT

      def name : String
        "UpdateGoal"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "status": {
              "type": "string",
              "enum": ["active", "complete", "blocked"],
              "description": "The lifecycle status to set for the current goal. Use `blocked` for impossible, unsafe, or contradictory objectives, or after the same non-terminal blocking condition repeats for at least 3 consecutive goal turns."
            }
          },
          "required": ["status"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        raw = input["status"]?.try(&.to_s) || ""
        status = parse_status(raw)
        return ToolResult.error("Invalid goal status. Use `active`, `complete`, or `blocked`.") if status.nil?

        service = Goal.service
        return ToolResult.error("Goal service is not initialized.") if service.nil?

        current = service.get_goal

        case status
        when .active?
          if current.nil?
            return ToolResult.success("Goal not resumed: no current goal.")
          end
          if current.status.goal_id_changed?(current) && !service.is_goal_tool_target?(nil, current.goal_id)
            return ToolResult.success("Goal not resumed: the current goal changed.")
          end
          begin
            snapshot = service.resume_goal(nil, "model")
          rescue ex : GoalError
            return ToolResult.error(ex.message || "Failed to resume goal.")
          end
          ToolResult.success("Goal resumed.")
        when .complete?
          if current.nil?
            return ToolResult.success("Goal not completed: no active goal.")
          end
          begin
            snapshot = service.mark_complete(nil, "model")
          rescue ex : GoalError
            return ToolResult.error(ex.message || "Failed to complete goal.")
          end
          return ToolResult.success("Goal not completed: no active goal.") if snapshot.nil?
          ToolResult.success(build_goal_completion_summary_prompt(snapshot))
        when .blocked?
          if current.nil?
            return ToolResult.success("Goal not blocked: no active goal.")
          end
          begin
            snapshot = service.mark_blocked(nil, "model")
          rescue ex : GoalError
            return ToolResult.error(ex.message || "Failed to block goal.")
          end
          return ToolResult.success("Goal not blocked: no active goal.") if snapshot.nil?
          ToolResult.success(build_goal_blocked_reason_prompt(snapshot))
        else
          ToolResult.error("Invalid goal status. Use `active`, `complete`, or `blocked`.")
        end
      end

      def parse_status(raw : String) : GoalStatus?
        case raw.downcase
        when "active"   then GoalStatus::Active
        when "complete" then GoalStatus::Complete
        when "blocked"  then GoalStatus::Blocked
        else
          nil
        end
      end

      def build_goal_completion_summary_prompt(snapshot : GoalSnapshot) : String
        terminal = snapshot.terminal_reason
        reason_clause = terminal ? ": #{terminal}" : ""
        turns = snapshot.turns_used
        elapsed_str = format_elapsed(snapshot.wall_clock_ms)
        tokens_str = format_tokens(snapshot.tokens_used)

        <<-TEXT
          Goal completed successfully#{reason_clause}.
          Worked #{turns == 1 ? "1 turn" : "#{turns} turns"} over #{elapsed_str}, using #{tokens_str} tokens.

          Write a concise final message for the user. State that the goal is complete, summarize the main work completed, and mention any validation you ran. Do not call more goal tools.
        TEXT
      end

      def build_goal_blocked_reason_prompt(snapshot : GoalSnapshot) : String
        turns = snapshot.turns_used
        elapsed_str = format_elapsed(snapshot.wall_clock_ms)
        tokens_str = format_tokens(snapshot.tokens_used)

        <<-TEXT
          Goal blocked.
          Worked #{turns == 1 ? "1 turn" : "#{turns} turns"} over #{elapsed_str}, using #{tokens_str} tokens.

          Write a concise final message for the user. State that the goal is blocked, explain the concrete blocker, and say what input or change is needed before work can continue. Do not call more goal tools.
        TEXT
      end

      def format_elapsed(ms : Int64) : String
        total_seconds = (ms // 1000).to_i32
        if total_seconds < 60
          "#{total_seconds}s"
        elsif total_seconds < 3600
          m = total_seconds // 60
          ss = total_seconds % 60
          "#{m}m#{ss.to_s.rjust(2, '0')}s"
        else
          h = total_seconds // 3600
          mm = (total_seconds % 3600) // 60
          "#{h}h#{mm.to_s.rjust(2, '0')}m"
        end
      end

      def format_tokens(n : Int32) : String
        if n < 1000
          n.to_s
        elsif n < 1_000_000
          "#{(n.to_f64 / 1000).round(1)}k"
        else
          "#{(n.to_f64 / 1_000_000).round(1)}M"
        end
      end
    end

    class SetGoalBudget < Tool
      DESCRIPTION = <<-TEXT
        Set a hard budget limit for the current goal.

        Use this only when the user clearly gives a runtime limit, such as:

        - "stop after 20 turns"
        - "use no more than 500k tokens"
        - "finish within 30 minutes"

        Do not invent limits. Do not call this for vague wording such as "spend some time" or
        "try to be quick".

        If the user gives a compound time, convert it to one supported unit before calling this tool.
        For example, "2 hours and 3 minutes" can be set as `value: 123, unit: "minutes"`.

        A time budget must be between 1 second and 24 hours — the tool rejects anything shorter or
        longer, telling the user it is not a reasonable goal budget. Turn and token budgets are not
        bounded this way; they must be positive and are rounded to the nearest whole number (minimum 1).

        Supported units:

        - `turns`
        - `tokens`
        - `milliseconds`
        - `seconds`
        - `minutes`
        - `hours`
      TEXT

      def name : String
        "SetGoalBudget"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "value": {
              "type": "number",
              "exclusiveMinimum": 0,
              "description": "The positive numeric budget value."
            },
            "unit": {
              "type": "string",
              "enum": ["turns", "tokens", "milliseconds", "seconds", "minutes", "hours"]
            }
          },
          "required": ["value", "unit"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        value_raw = input["value"]?
        return ToolResult.error("`value` is required.") if value_raw.nil?
        value = value_raw.as_f? || value_raw.as_i?.try(&.to_f64)
        return ToolResult.error("`value` must be a positive number.") if value.nil? || value <= 0

        unit = input["unit"]?.try(&.to_s) || ""
        return ToolResult.error("`unit` is required.") if unit.empty?
        return ToolResult.error("Unsupported unit: #{unit}.") unless Goal::BUDGET_UNITS.includes?(unit)

        service = Goal.service
        return ToolResult.error("Goal service is not initialized.") if service.nil?

        current = service.get_goal
        return ToolResult.success("Goal budget not set: no current goal.") if current.nil?

        limits = budget_limits_from_input(value, unit)
        if limits.nil?
          return ToolResult.success("Goal budget not set: #{format_budget(value, unit)} is not a reasonable goal budget.")
        end

        begin
          snapshot = service.set_budget_limits(BudgetInput.new(limits), "model")
        rescue ex : GoalError
          return ToolResult.error(ex.message || "Failed to set budget.")
        end

        if snapshot.budget.over_budget?
          ToolResult.success("Goal budget set: #{format_budget(value, unit)}. The goal has already reached this budget and will stop now.")
        else
          ToolResult.success("Goal budget set: #{format_budget(value, unit)}.")
        end
      end

      def budget_limits_from_input(value : Float64, unit : String) : GoalBudgetLimits?
        case unit
        when "turns"
          GoalBudgetLimits.new(turn_budget: [1, value.round.to_i32].max)
        when "tokens"
          GoalBudgetLimits.new(token_budget: [1, value.round.to_i32].max)
        when "milliseconds", "seconds", "minutes", "hours"
          ms = to_milliseconds(value, unit).round.to_i64
          return nil if ms < Goal::MIN_REASONABLE_TIME_BUDGET_MS || ms > Goal::MAX_REASONABLE_TIME_BUDGET_MS
          GoalBudgetLimits.new(wall_clock_budget_ms: ms)
        else
          nil
        end
      end

      def to_milliseconds(value : Float64, unit : String) : Float64
        case unit
        when "milliseconds" then value
        when "seconds"      then value * 1000
        when "minutes"      then value * 60_000
        when "hours"        then value * 3_600_000
        else                     value
        end
      end

      def format_budget(value : Float64, unit : String) : String
        # Грамматика: 1 turn / 2 turns, 1 token, 1 millisecond/second/minute/hour.
        int_value = value.round.to_i64
        singular = unit.ends_with?('s') ? unit[0...-1] : unit
        "#{int_value} #{int_value == 1 ? singular : unit}"
      end
    end
  end
end
