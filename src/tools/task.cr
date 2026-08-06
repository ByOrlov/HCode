module Hcode
  module Tools
    # Background-task tools — TaskList, TaskOutput, TaskStop.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/agent/task/tools/`.
    #
    # Все 3 тула регистрируются только для main agent (как goal-тулы).
    #
    # См. детальный план портирования в `md-tools/task.md`.
    module Task
      OUTPUT_PREVIEW_BYTES = 32 * 1024
      PAGING_HINT_LINES    = 300

      TERMINAL_STATUSES = {
        AgentTaskStatus::Completed,
        AgentTaskStatus::Failed,
        AgentTaskStatus::TimedOut,
        AgentTaskStatus::Killed,
        AgentTaskStatus::Lost,
      }

      @@service : TaskService?

      def self.service=(s : TaskService?)
        @@service = s
      end

      def self.service : TaskService?
        @@service
      end
    end

    enum AgentTaskStatus
      Running
      Completed
      Failed
      TimedOut
      Killed
      Lost

      def to_wire : String
        case self
        in Running   then "running"
        in Completed then "completed"
        in Failed    then "failed"
        in TimedOut  then "timed_out"
        in Killed    then "killed"
        in Lost      then "lost"
        end
      end

      def completed? : Bool
        self == AgentTaskStatus::Completed
      end

      def terminal? : Bool
        Task::TERMINAL_STATUSES.includes?(self)
      end
    end

    class AgentTaskInfo
      property task_id : String
      property description : String
      property status : AgentTaskStatus
      property detached : Bool?
      property started_at : Int64
      property ended_at : Int64?
      property stop_reason : String?
      property terminal_notification_suppressed : Bool?
      property timeout_ms : Int64?
      # shell-task specific (kind = "bash"):
      property command : String?
      property pid : Int64?
      property exit_code : Int32?

      def initialize(@task_id : String,
                     @description : String,
                     @status : AgentTaskStatus,
                     @started_at : Int64,
                     @ended_at : Int64? = nil,
                     @detached : Bool? = nil,
                     @stop_reason : String? = nil,
                     @terminal_notification_suppressed : Bool? = nil,
                     @timeout_ms : Int64? = nil,
                     @command : String? = nil,
                     @pid : Int64? = nil,
                     @exit_code : Int32? = nil)
      end

      def profiled_bytes : Int64
        total = @task_id.profiled_bytes + @description.profiled_bytes
        total += @stop_reason.try(&.profiled_bytes) || 0_i64
        total += @command.try(&.profiled_bytes) || 0_i64
        total
      end

      # ----------------------------------------------------------------
      # JSON serialization for persistence.
      # ----------------------------------------------------------------

      def to_json_str : String
        JSON.build do |json|
          json.object do
            json.field "task_id", @task_id
            json.field "description", @description
            json.field "status", @status.to_wire
            json.field "started_at", @started_at
            json.field "ended_at", @ended_at unless @ended_at.nil?
            json.field "detached", @detached unless @detached.nil?
            json.field "stop_reason", @stop_reason unless @stop_reason.nil?
            if v = @terminal_notification_suppressed
              json.field "terminal_notification_suppressed", v
            end
            json.field "timeout_ms", @timeout_ms unless @timeout_ms.nil?
            json.field "command", @command unless @command.nil?
            json.field "pid", @pid unless @pid.nil?
            json.field "exit_code", @exit_code unless @exit_code.nil?
          end
        end
      end

      def self.from_json_obj(parsed : JSON::Any) : AgentTaskInfo
        status = case parsed["status"]?.try(&.to_s)
                 when "completed" then AgentTaskStatus::Completed
                 when "failed"    then AgentTaskStatus::Failed
                 when "timed_out" then AgentTaskStatus::TimedOut
                 when "killed"    then AgentTaskStatus::Killed
                 when "lost"      then AgentTaskStatus::Lost
                 else                  AgentTaskStatus::Running
                 end
        info = AgentTaskInfo.new(
          task_id: parsed["task_id"]?.try(&.to_s) || "",
          description: parsed["description"]?.try(&.to_s) || "",
          status: status,
          started_at: parsed["started_at"]?.try(&.as_i64) || 0_i64,
        )
        info.ended_at = parsed["ended_at"]?.try(&.as_i64?)
        info.detached = parsed["detached"]?.try(&.as_bool?)
        sr = parsed["stop_reason"]?
        info.stop_reason = sr ? sr.to_s : nil
        if v = parsed["terminal_notification_suppressed"]?.try(&.as_bool?)
          info.terminal_notification_suppressed = v
        end
        info.timeout_ms = parsed["timeout_ms"]?.try(&.as_i64?)
        cmd = parsed["command"]?
        info.command = cmd ? cmd.to_s : nil
        info.pid = parsed["pid"]?.try(&.as_i64?)
        info.exit_code = parsed["exit_code"]?.try(&.as_i?)
        info
      end
    end

    struct AgentTaskOutputSnapshot
      property output_path : String?
      property output_size_bytes : Int32
      property preview_bytes : Int32
      property? truncated : Bool
      property? full_output_available : Bool
      property preview : String

      def initialize(@output_path : String? = nil,
                     @output_size_bytes : Int32 = 0,
                     @preview_bytes : Int32 = 0,
                     @truncated : Bool = false,
                     @full_output_available : Bool = false,
                     @preview : String = "")
      end

      def profiled_bytes : Int64
        (@output_path.try(&.profiled_bytes) || 0_i64) + @preview.profiled_bytes
      end
    end

    class TaskError < Exception
    end

    abstract class TaskService
      abstract def list(active_only : Bool = true, limit : Int32 = 20) : Array(AgentTaskInfo)
      abstract def get_task(task_id : String) : AgentTaskInfo?
      abstract def get_output_snapshot(task_id : String, max_preview_bytes : Int32) : AgentTaskOutputSnapshot
      abstract def suppress_terminal_notification(task_id : String) : Nil
      abstract def notification_suppressed?(task_id : String) : Bool
      abstract def stop(task_id : String, reason : String? = nil) : AgentTaskInfo?
      abstract def stop_by_user(task_id : String) : AgentTaskInfo?
      abstract def stop_all(reason : String? = nil) : Array(AgentTaskInfo)
      abstract def stop_all_on_exit(reason : String) : Array(AgentTaskInfo)
      abstract def wait(task_id : String, timeout_ms : Int64? = nil) : AgentTaskInfo?
      abstract def detach(task_id : String) : AgentTaskInfo?
    end

    # In-memory TaskService with optional process tracking and persistence.
    # Stores task metadata + output. When a live process is attached via
    # `register_process`, stop/wait perform a real SIGTERM→grace→SIGKILL and
    # blocking exit wait. Optionally persists metadata to `Session::Store`.
    class InMemoryTaskService < TaskService
      @tasks = {} of String => AgentTaskInfo
      @outputs = {} of String => AgentTaskOutputSnapshot
      @handles = {} of String => TaskHandle
      @store : Session::Store?
      @task_counter = 0

      def initialize(@store : Session::Store? = nil)
      end

      def profiled_bytes : Int64
        tasks_bytes = @tasks.values.sum(&.profiled_bytes)
        outputs_bytes = @outputs.values.sum(&.profiled_bytes)
        tasks_bytes + outputs_bytes
      end

      def profiled_count : Int32
        @tasks.size
      end

      def register(info : AgentTaskInfo) : AgentTaskInfo
        @tasks[info.task_id] = info
        @handles[info.task_id] ||= TaskHandle.new
        persist_task_meta(info.task_id)
        info
      end

      # Associate a live process with a registered task. The task must
      # already be in `@tasks` (via `register`). The exit channel is
      # expected to receive exactly one `Process::Status` when the
      # process terminates.
      def register_process(task_id : String, process : Process,
                           exit_channel : Channel(Process::Status)) : Nil
        handle = @handles[task_id]? || (return)
        handle.process = process
        handle.exit_channel = exit_channel
      end

      def set_output(task_id : String, preview : String, *,
                     output_path : String? = nil,
                     full_output_available : Bool = false,
                     truncated : Bool = false) : Nil
        @outputs[task_id] = AgentTaskOutputSnapshot.new(
          output_path: output_path,
          output_size_bytes: preview.bytesize,
          preview_bytes: preview.bytesize,
          truncated: truncated,
          full_output_available: full_output_available,
          preview: preview,
        )
      end

      def list(active_only : Bool = true, limit : Int32 = 20) : Array(AgentTaskInfo)
        items = @tasks.values
        items = items.reject(&.status.terminal?) if active_only
        items.sort_by!(&.started_at)
        items.first(limit.clamp(1, 100))
      end

      def get_task(task_id : String) : AgentTaskInfo?
        @tasks[task_id]?
      end

      def get_output_snapshot(task_id : String, max_preview_bytes : Int32) : AgentTaskOutputSnapshot
        snap = @outputs[task_id]?
        return AgentTaskOutputSnapshot.new unless snap
        if snap.preview.bytesize <= max_preview_bytes
          return snap
        end
        # Tail of preview beyond max_preview_bytes (truncation marker).
        start_idx = Math.min(max_preview_bytes, snap.preview.bytesize)
        tail = snap.preview.byte_slice(start_idx)
        AgentTaskOutputSnapshot.new(
          output_path: snap.output_path,
          output_size_bytes: snap.output_size_bytes,
          preview_bytes: max_preview_bytes,
          truncated: true,
          full_output_available: snap.full_output_available?,
          preview: tail,
        )
      end

      def suppress_terminal_notification(task_id : String) : Nil
        task = @tasks[task_id]?
        return if task.nil?
        task.terminal_notification_suppressed = true
        if handle = @handles[task_id]?
          handle.suppressed = true
        end
      end

      def notification_suppressed?(task_id : String) : Bool
        @handles[task_id]?.try(&.suppressed?) || false
      end

      def stop(task_id : String, reason : String? = nil) : AgentTaskInfo?
        task = @tasks[task_id]?
        return nil if task.nil?
        return task if task.status.terminal?
        if handle = @handles[task_id]?
          if process = handle.process
            kill_process(process)
            if ch = handle.exit_channel
              select
              when ch.receive
              when timeout(6.seconds)
              end
            end
            unless task.status.terminal?
              task.status = AgentTaskStatus::Killed
              task.stop_reason = reason || "Stopped by TaskStop"
              task.ended_at = Time.utc.to_unix_ms
            end
          else
            task.status = AgentTaskStatus::Killed
            task.stop_reason = reason || "Stopped by TaskStop"
            task.ended_at = Time.utc.to_unix_ms
          end
        else
          task.status = AgentTaskStatus::Killed
          task.stop_reason = reason || "Stopped by TaskStop"
          task.ended_at = Time.utc.to_unix_ms
        end
        persist_task_meta(task_id)
        task
      end

      def stop_by_user(task_id : String) : AgentTaskInfo?
        stop(task_id, "Stopped by user")
      end

      def stop_all(reason : String? = nil) : Array(AgentTaskInfo)
        stopped = [] of AgentTaskInfo
        @tasks.each_key do |task_id|
          task = @tasks[task_id]
          next if task.status.terminal?
          if handle = @handles[task_id]?
            if process = handle.process
              kill_process(process)
              if ch = handle.exit_channel
                select
                when ch.receive
                when timeout(6.seconds)
                end
              end
              unless task.status.terminal?
                task.status = AgentTaskStatus::Killed
                task.stop_reason = reason || "Stopped"
                task.ended_at = Time.utc.to_unix_ms
              end
            else
              task.status = AgentTaskStatus::Killed
              task.stop_reason = reason || "Stopped"
              task.ended_at = Time.utc.to_unix_ms
            end
          else
            task.status = AgentTaskStatus::Killed
            task.stop_reason = reason || "Stopped"
            task.ended_at = Time.utc.to_unix_ms
          end
          stopped << task
          persist_task_meta(task_id)
        end
        stopped
      end

      def stop_all_on_exit(reason : String) : Array(AgentTaskInfo)
        stop_all(reason)
      end

      def wait(task_id : String, timeout_ms : Int64? = nil) : AgentTaskInfo?
        task = @tasks[task_id]?
        return nil if task.nil?
        return task if task.status.terminal?
        handle = @handles[task_id]?
        return task unless handle && (ch = handle.exit_channel)
        if t = timeout_ms
          select
          when ch.receive
          when timeout(t.milliseconds)
          end
        else
          ch.receive
        end
        @tasks[task_id]?
      end

      def detach(task_id : String) : AgentTaskInfo?
        task = @tasks[task_id]?
        return nil if task.nil?
        task.detached = true
        persist_task_meta(task_id)
        task
      end

      # ----------------------------------------------------------------
      # Persistence + reconcile
      # ----------------------------------------------------------------

      # Persist the current task metadata to the store (if configured).
      def persist_task_meta(task_id : String) : Nil
        s = @store
        task = @tasks[task_id]?
        return if s.nil? || task.nil?
        s.write_task_meta(task_id, task.to_json_str)
      end

      # Load persisted task metadata from the store and mark any non-terminal
      # tasks as `Lost` (the previous process died with its parent). Called
      # on session resume. Returns the list of lost tasks.
      def mark_lost_on_resume : Array(AgentTaskInfo)
        s = @store
        return [] of AgentTaskInfo if s.nil?
        now_ms = Time.utc.to_unix_ms
        lost = [] of AgentTaskInfo
        s.read_task_metas.each do |(task_id, parsed)|
          info = AgentTaskInfo.from_json_obj(parsed)
          next if info.task_id.empty?
          # Skip tasks already live (e.g. subagents registered this session).
          next if @tasks.has_key?(info.task_id)
          unless info.status.terminal?
            info.status = AgentTaskStatus::Lost
            info.ended_at = now_ms
            info.stop_reason = "Session resumed; process is no longer reachable"
            s.write_task_meta(info.task_id, info.to_json_str)
          end
          @tasks[info.task_id] = info
          @handles[info.task_id] ||= TaskHandle.new
          lost << info if info.status == AgentTaskStatus::Lost
        end
        lost
      end

      # ----------------------------------------------------------------
      # Private helpers
      # ----------------------------------------------------------------

      # Two-phase kill: SIGTERM, then SIGKILL after a 5s grace window —
      # mirrors the JS BackgroundManager kill ladder. Sends SIGTERM, waits
      # up to 5s on a separate fiber, then escalates to SIGKILL if still alive.
      private def kill_process(process : Process) : Nil
        process.terminate rescue nil
        spawn do
          sleep 5.seconds
          if process.exists?
            Tool::PROCESS_PORT.force_kill(process)
          end
        end
      end

      def next_task_id(prefix : String = "task") : String
        @task_counter += 1
        "#{prefix}-#{@task_counter}"
      end
    end

    # Tracks a live background task's OS process handle, exit channel, and
    # notification-suppression flag. Lives only in-process — never persisted.
    class TaskHandle
      property process : Process?
      property exit_channel : Channel(Process::Status)?
      property output_path : String?
      property? suppressed : Bool = false

      def initialize
      end
    end

    # --------------------------------------------------------------------
    # Utils
    # --------------------------------------------------------------------

    # Конвертирует CamelCase/PascalCase в snake_case (как JS
    # `key.replaceAll(/[A-Z]/g, "_$&".toLowerCase())`).
    def self.snake_case_key(key : String) : String
      String.build do |io|
        key.each_char do |c|
          if c.uppercase?
            io << '_'
            io << c.downcase
          else
            io << c
          end
        end
      end
    end

    # Рендерит record в формате "key: value\n" построчно, опуская nil,
    # конвертируя ключи в snake_case. Принимает упорядоченный список пар.
    # Значение уже stringified или nil (для фильтрации).
    def self.format_plain_object(pairs : Array(Tuple(String, String?))) : String
      parts = [] of String
      pairs.each do |(k, v)|
        next if v.nil?
        parts << "#{snake_case_key(k)}: #{v}"
      end
      parts.join('\n')
    end

    # --------------------------------------------------------------------
    # Tools
    # --------------------------------------------------------------------

    class TaskList < Tool
      DESCRIPTION = <<-TEXT
        List background tasks and their current status.

        Use this tool to discover which background tasks exist and where each one
        stands. It is the entry point for inspecting background work: it returns a
        task ID, status, and description for every task it reports, plus the command,
        PID, and (once finished) exit code for shell tasks, and a stop reason for any
        task that ended early.

        Guidelines:

        - After a context compaction, or whenever you are unsure which background
          tasks are running or what their task IDs are, call this tool to
          re-enumerate them instead of guessing a task ID.
        - Prefer the default `active_only=true`, which lists only non-terminal tasks.
          Pass `active_only=false` only when you specifically need to see tasks that
          have already finished. With `active_only=false` the result may also include
          `lost` tasks — tasks left over from a previous process that can no longer be
          inspected or controlled; treat them as already terminated.
        - `limit` caps how many tasks are returned. It accepts a value between 1 and
          100 and defaults to 20 when omitted.
        - This tool only lists tasks; it does not return their output. Use it first
          to locate the task ID you need, then call `TaskOutput` with that ID to read
          the task's output and details.
        - This tool is read-only and does not change any state, so it is always safe
          to call, including in plan mode.
      TEXT

      def name : String
        "TaskList"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "active_only": {
              "type": "boolean",
              "default": true,
              "description": "Whether to list only non-terminal background tasks."
            },
            "limit": {
              "type": "integer",
              "minimum": 1,
              "maximum": 100,
              "default": 20,
              "description": "Maximum number of tasks to return."
            }
          },
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Task.service
        return ToolResult.error("Task service is not initialized.") if service.nil?

        active_only = input["active_only"]?.try(&.as_bool?)
        active_only = true if active_only.nil?
        limit_raw = input["limit"]?.try(&.as_i?) || 20
        limit = limit_raw.clamp(1, 100)

        tasks = service.list(active_only, limit)
        ToolResult.success(format_task_list(tasks, active_only))
      end

      def format_task_list(tasks : Array(AgentTaskInfo), active_only : Bool) : String
        label = active_only ? "active_background_tasks" : "background_tasks"
        return "#{label}: 0\nNo background tasks found." if tasks.empty?

        body = tasks.map { |t| format_record(t) }.join("\n---\n")
        "#{label}: #{tasks.size}\n#{body}"
      end

      def format_record(task : AgentTaskInfo) : String
        pairs = [] of Tuple(String, String?)
        pairs << {"taskId", task.task_id}
        pairs << {"description", task.description}
        pairs << {"status", task.status.to_wire}
        pairs << {"startedAt", task.started_at.to_s}
        pairs << {"endedAt", task.ended_at.try(&.to_s)}
        pairs << {"stopReason", task.stop_reason}
        pairs << {"timeoutMs", task.timeout_ms.try(&.to_s)}
        pairs << {"detached", task.detached.try(&.to_s)}
        pairs << {"command", task.command}
        pairs << {"pid", task.pid.try(&.to_s)}
        pairs << {"exitCode", task.exit_code.try(&.to_s)}
        Tools.format_plain_object(pairs)
      end
    end

    class TaskOutput < Tool
      DESCRIPTION = <<-TEXT
        Retrieve a snapshot of a running or completed background task.

        Use this after `Bash(run_in_background=true)` or `Agent(run_in_background=true)` to check progress, or to read the output of a task that has already completed.

        Guidelines:
        - Prefer relying on automatic completion notifications. Use this tool only when you need task output before the automatic notification arrives.
        - By default this tool is non-blocking and returns a current status/output snapshot — that is the normal way to use it.
        - Do not use TaskOutput to wait for a result you need before continuing — if your next step depends on the task's result, run that task in the foreground instead. TaskOutput is for a deliberate progress check you will act on without blocking, not a way to sit and wait for a background task you just launched.
        - Use block=true only when the user explicitly asked you to wait for the task. Never block on a task you launched in the current turn — if you need its result right away, it should have been a foreground call.
        - If a block=true call returns `retrieval_status: timeout` (the task is still running), do not block on the same task again. Continue with other work or hand back to the user — the completion notification arrives on its own.
        - This tool returns structured task metadata, a fixed-size output preview, and an output_path for the full log.
        - For a terminal task, the metadata also explains why it ended. A shell command that runs to completion reports `status: completed` on a zero exit, or `status: failed` with its non-zero `exit_code` — judge that failure from the `exit_code`, because a plain command failure carries no `stop_reason` and no `terminal_reason`. `terminal_reason` is a categorical label emitted only when the end is not an ordinary exit: `timed_out` when the deadline aborted it, `stopped` when it was explicitly stopped, or `failed` when it errored without producing an exit code; the `stopped` and `failed` cases also carry a human-readable `stop_reason`. A task that finished on its own with a clean exit carries neither `stop_reason` nor `terminal_reason`.
        - The full, never-truncated log is always available at output_path; use the `Read` tool with that path to page through it, whether or not the preview was truncated.
        - This tool works with the generic background task system and should remain the primary read path for future task types, not just bash.
      TEXT

      def name : String
        "TaskOutput"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "task_id": {
              "type": "string",
              "description": "The background task ID to inspect."
            },
            "block": {
              "type": "boolean",
              "default": false,
              "description": "Whether to wait for the task to finish before returning. Discouraged — background tasks notify automatically on completion; use only when the user explicitly asked you to wait."
            },
            "timeout": {
              "type": "integer",
              "minimum": 0,
              "maximum": 3600,
              "default": 30,
              "description": "Maximum number of seconds to wait when block=true."
            }
          },
          "required": ["task_id"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Task.service
        return ToolResult.error("Task service is not initialized.") if service.nil?

        task_id = input["task_id"]?.try(&.to_s) || ""
        return ToolResult.error("`task_id` is required.") if task_id.empty?

        block = input["block"]?.try(&.as_bool?) || false
        timeout_s = input["timeout"]?.try(&.as_i?) || 30

        svc = service
        info = svc.get_task(task_id)
        return ToolResult.error("Task not found: #{task_id}") if info.nil?

        if block && !info.status.terminal?
          svc.wait(task_id, (timeout_s.to_i64 * 1000))
          current = svc.get_task(task_id)
          return ToolResult.error("Task not found: #{task_id}") if current.nil?
          info = current
        end

        output = svc.get_output_snapshot(task_id, Task::OUTPUT_PREVIEW_BYTES)

        ToolResult.success(render(info, output, block))
      end

      def render(info : AgentTaskInfo, output : AgentTaskOutputSnapshot, block : Bool) : String
        terminal = info.status.terminal?
        retrieval = retrieval_status(info.status, block)
        term_reason = terminal_reason(info)

        pairs = [] of Tuple(String, String?)
        pairs << {"retrievalStatus", retrieval}
        pairs << {"taskId", info.task_id}
        pairs << {"description", info.description}
        pairs << {"status", info.status.to_wire}
        pairs << {"startedAt", info.started_at.to_s}
        pairs << {"endedAt", info.ended_at.try(&.to_s)}
        pairs << {"stopReason", info.stop_reason}
        pairs << {"timeoutMs", info.timeout_ms.try(&.to_s)}
        pairs << {"detached", info.detached.try(&.to_s)}
        pairs << {"command", info.command}
        pairs << {"pid", info.pid.try(&.to_s)}
        pairs << {"exitCode", info.exit_code.try(&.to_s)}
        pairs << {"terminalReason", term_reason}
        pairs << {"outputPath", output.output_path}
        pairs << {"outputSizeBytes", output.output_size_bytes.to_s}
        pairs << {"outputPreviewBytes", output.preview_bytes.to_s}
        pairs << {"outputTruncated", output.truncated?.to_s}
        pairs << {"fullOutputAvailable", output.full_output_available?.to_s}

        hint = full_output_hint(output)
        unless hint.nil?
          pairs << {"fullOutputTool", "Read"}
          pairs << {"fullOutputHint", hint}
        end

        next_step = self.next_step(block, terminal)
        pairs << {"nextStep", next_step} unless next_step.nil?

        body = Tools.format_plain_object(pairs)

        String.build do |io|
          io << body
          io << "\n\n"
          if output.truncated?
            if output.full_output_available? && (path = output.output_path)
              io << "[Truncated. Full output: #{path}]"
            else
              io << "[Truncated. No persisted full log is available for this task.]"
            end
            io << "\n\n"
          end
          io << "[output]\n"
          io << (output.preview.empty? ? "[no output available]" : output.preview)
        end
      end

      def retrieval_status(status : AgentTaskStatus, block : Bool) : String
        if status.terminal?
          "success"
        elsif block
          "timeout"
        else
          "not_ready"
        end
      end

      def terminal_reason(info : AgentTaskInfo) : String?
        case info.status
        when AgentTaskStatus::TimedOut
          "timed_out"
        when AgentTaskStatus::Killed
          info.stop_reason.nil? ? nil : "stopped"
        when AgentTaskStatus::Failed
          info.stop_reason.nil? ? nil : "failed"
        else
          nil
        end
      end

      def full_output_hint(output : AgentTaskOutputSnapshot) : String?
        return nil if !output.full_output_available? || output.output_path.nil?
        if output.truncated?
          "Only the last #{Task::OUTPUT_PREVIEW_BYTES} bytes are shown above. Use the Read tool with the output_path to page through the full log (parameters: path, line_offset, n_lines; read about #{Task::PAGING_HINT_LINES} lines per page)."
        else
          "The preview above is the complete output. Use the Read tool with the output_path if you need to re-read the full log later (parameters: path, line_offset, n_lines; read about #{Task::PAGING_HINT_LINES} lines per page)."
        end
      end

      def next_step(block : Bool, terminal : Bool) : String?
        return nil if !block || terminal
        "The task is still running after waiting. Do not block on it again — continue with other work or hand back to the user; you will be notified automatically when it completes."
      end
    end

    class TaskStop < Tool
      DESCRIPTION = <<-TEXT
        Stop a running background task.

        Only use this when a task must genuinely be cancelled — for a task that is
        finishing normally, wait for its completion notification or inspect it with
        `TaskOutput` instead of stopping it.

        Guidelines:
        - This is a general-purpose stop capability for any background task. It is not
          a bash-specific kill.
        - Stopping a task is destructive: it may leave partial side effects behind.
          Use it with care.
        - If the task has already finished, this tool simply returns its current
          status.
      TEXT

      DEFAULT_REASON = "Stopped by TaskStop"

      def name : String
        "TaskStop"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "task_id": {
              "type": "string",
              "description": "The background task ID to stop."
            },
            "reason": {
              "type": "string",
              "default": "Stopped by TaskStop",
              "description": "Short reason recorded when the task is stopped."
            }
          },
          "required": ["task_id"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Task.service
        return ToolResult.error("Task service is not initialized.") if service.nil?

        task_id = input["task_id"]?.try(&.to_s) || ""
        return ToolResult.error("`task_id` is required.") if task_id.empty?

        svc = service
        info = svc.get_task(task_id)
        return ToolResult.error("Task not found: #{task_id}") if info.nil?

        reason = input["reason"]?.try(&.to_s)
        reason = (reason && !reason.strip.empty?) ? reason.strip : DEFAULT_REASON

        if info.status.terminal?
          return ToolResult.success(render_terminal(info))
        end

        svc.suppress_terminal_notification(task_id)
        result = svc.stop(task_id, reason)
        return ToolResult.error("Failed to stop task: #{task_id}") if result.nil?

        ToolResult.success(render_stopped(result, reason))
      end

      def render_terminal(info : AgentTaskInfo) : String
        reason = terminal_stop_reason(info.stop_reason)
        pairs = [] of Tuple(String, String?)
        pairs << {"taskId", info.task_id}
        pairs << {"status", info.status.to_wire}
        pairs << {"reason", reason}
        Tools.format_plain_object(pairs)
      end

      def render_stopped(info : AgentTaskInfo, requested_reason : String) : String
        pairs = [] of Tuple(String, String?)
        pairs << {"taskId", info.task_id}
        pairs << {"status", info.status.to_wire}
        pairs << {"reason", info.stop_reason || requested_reason}
        Tools.format_plain_object(pairs)
      end

      def terminal_stop_reason(reason : String?) : String
        r = reason.try(&.strip)
        (r && !r.empty?) ? r : "Task already in terminal state"
      end
    end

    # --------------------------------------------------------------------
    # render_notification_xml — рендерит XML-блок для injection в context
    # при завершении detached-задачи.
    # --------------------------------------------------------------------

    def self.escape_xml_attr(value : String) : String
      String.build do |io|
        value.each_char do |c|
          case c
          when '"'  then io << "&quot;"
          when '&'  then io << "&amp;"
          when '<'  then io << "&lt;"
          when '>'  then io << "&gt;"
          when '\n' then io << "&#10;"
          when '\r' then io << "&#13;"
          when '\t' then io << "&#9;"
          else           io << c
          end
        end
      end
    end

    def self.render_notification_xml(data : Hash(String, JSON::Any)) : String
      id_val = string_attr(data["id"]?, "unknown")
      category = string_attr(data["category"]?, "unknown")
      type_val = string_attr(data["type"]?, "unknown")
      source_kind = string_attr(data["source_kind"]?, "unknown")
      source_id = string_attr(data["source_id"]?, "unknown")
      agent_id = optional_string_attr(data["agent_id"]?)
      title = data["title"]?.try(&.as_s?) || ""
      severity = data["severity"]?.try(&.as_s?) || ""
      body = data["body"]?.try(&.as_s?) || ""
      children = child_blocks(data["children"]? || data["extraBlocks"]?)

      agent_attr = agent_id ? " agent_id=\"#{agent_id}\"" : ""
      lines = ["<notification id=\"#{id_val}\" category=\"#{category}\" type=\"#{type_val}\" source_kind=\"#{source_kind}\" source_id=\"#{source_id}\"#{agent_attr}>"]
      lines << "Title: #{title}" unless title.empty?
      lines << "Severity: #{severity}" unless severity.empty?
      lines << body unless body.empty?
      children.each { |c| lines << c }
      lines << "</notification>"
      lines.join('\n')
    end

    def self.string_attr(v : JSON::Any?, fallback : String) : String
      s = v.try(&.as_s?)
      return fallback if s.nil? || s.empty?
      escape_xml_attr(s)
    end

    def self.optional_string_attr(v : JSON::Any?) : String?
      s = v.try(&.as_s?)
      return nil if s.nil? || s.empty?
      escape_xml_attr(s)
    end

    def self.child_blocks(v : JSON::Any?) : Array(String)
      return [] of String if v.nil?
      if s = v.as_s?
        return [s]
      end
      if a = v.as_a?
        result = [] of String
        a.each do |e|
          next unless e2 = e.as_s?
          next if e2.empty?
          result << e2
        end
        return result
      end
      [] of String
    end
  end
end
