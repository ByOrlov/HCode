module H2code
  module Hooks
    # Hook lifecycle events. Mirrors the TS `HOOK_EVENT_TYPES` subset that the
    # agent loop actually fires; the full list lives in the TS types file.
    enum EventType
      PreToolUse
      PostToolUse
      PostToolUseFailure
      UserPromptSubmit
      Stop
      StopFailure
      SessionStart
      SessionEnd
      PreCompact
      PostCompact
      Interrupt
      Notification

      def to_s(io : IO) : Nil
        io << to_s_raw
      end

      # The wire / config string form (PascalCase, matches TS exactly).
      def to_s_raw : String
        super
      end
    end

    # One hook definition, parsed from a `[[hooks]]` table in config.json:
    #
    #   [[hooks]]
    #   event = "PreToolUse"
    #   matcher = Tools::Names::BASH        # regex, empty = match all
    #   command = "echo blocked"
    #   timeout = 30            # seconds
    struct HookDef
      getter event : String
      getter matcher : String
      getter command : String
      getter timeout : Int32
      getter cwd : String?
      getter env : Hash(String, String)?

      def initialize(@event : String,
                     @command : String,
                     @matcher : String = "",
                     @timeout : Int32 = 30,
                     @cwd : String? = nil,
                     @env : Hash(String, String)? = nil)
      end
    end

    # Outcome of running one hook command.
    struct HookResult
      getter action : String # "allow" | "block"
      getter message : String?
      getter reason : String?
      getter stdout : String
      getter stderr : String
      getter exit_code : Int32
      getter? timed_out : Bool

      def initialize(@action : String = "allow",
                     @message : String? = nil,
                     @reason : String? = nil,
                     @stdout : String = "",
                     @stderr : String = "",
                     @exit_code : Int32 = 0,
                     @timed_out : Bool = false)
      end

      def block? : Bool
        @action == "block"
      end
    end

    # A decision to block an action, with the human-readable reason. Returned
    # by `trigger_block` when any matched hook blocks.
    struct BlockDecision
      getter reason : String

      def initialize(@reason : String)
      end
    end

    DEFAULT_TIMEOUT_SECONDS =  30
    KILL_GRACE_MS           = 100

    # Runs hook commands on demand, grouped by event. Hook commands are shell
    # strings that receive a JSON payload on stdin and signal their decision
    # via exit code (2 = block) or structured JSON output
    # (`{"hookSpecificOutput":{"permissionDecision":"deny"}}`).
    class Engine
      @by_event = {} of String => Array(HookDef)

      getter cwd : String?
      getter session_id : String?

      def initialize(hooks : Array(HookDef) = [] of HookDef,
                     @cwd : String? = nil,
                     @session_id : String? = nil)
        hooks.each do |hook|
          arr = @by_event[hook.event]? || (@by_event[hook.event] = [] of HookDef)
          arr << hook
        end
      end

      # True when no hooks are registered for any event.
      def empty? : Bool
        @by_event.all? { |_, v| v.empty? }
      end

      # Count of registered hooks per event (for status display).
      def summary : Hash(String, Int32)
        result = {} of String => Int32
        @by_event.each { |event, hooks| result[event] = hooks.size }
        result
      end

      # Trigger all hooks matching `event` + `matcher_value`, returning every
      # result. Never raises — a hook error is reported as an allow result.
      def trigger(event : String, matcher_value : String = "",
                  input : Hash(String, JSON::Any) = {} of String => JSON::Any) : Array(HookResult)
        matched = matching_hooks(event, matcher_value)
        return [] of HookResult if matched.empty?

        full_input = build_input(event, matcher_value, input)
        matched.map do |hook|
          run_hook(hook, full_input)
        end
      rescue
        [] of HookResult
      end

      # Like `trigger` but returns a BlockDecision when any result blocks.
      def trigger_block(event : String, matcher_value : String = "",
                        input : Hash(String, JSON::Any) = {} of String => JSON::Any) : BlockDecision?
        results = trigger(event, matcher_value, input)
        block = results.find(&.block?)
        if b = block
          BlockDecision.new(b.reason || b.message || "blocked by hook #{event}")
        end
      end

      private def matching_hooks(event : String, matcher_value : String) : Array(HookDef)
        hooks = @by_event[event]? || [] of HookDef
        seen = Set(String).new
        matched = [] of HookDef

        hooks.each do |hook|
          next unless matches?(hook.matcher, matcher_value)
          key = "#{hook.cwd}\0#{hook.command}"
          next if seen.includes?(key)
          seen << key
          matched << hook
        end

        matched
      end

      private def matches?(pattern : String, value : String) : Bool
        return true if pattern.empty?
        regex = Regex.new(pattern) rescue return false
        !!(regex.match(value))
      end

      private def build_input(event : String, matcher_value : String,
                              extra : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        input = {} of String => JSON::Any
        input["hook_event_name"] = JSON::Any.new(event)
        input["session_id"] = JSON::Any.new(@session_id || "")
        input["cwd"] = JSON::Any.new(@cwd || "")
        input["matcher"] = JSON::Any.new(matcher_value)
        extra.each { |k, v| input[k] = v }
        input
      end

      private def run_hook(hook : HookDef, input : Hash(String, JSON::Any)) : HookResult
        json = input.to_json
        timeout = hook.timeout > 0 ? hook.timeout : DEFAULT_TIMEOUT_SECONDS
        cwd = hook.cwd || @cwd

        stdout = IO::Memory.new
        stderr = IO::Memory.new
        env = hook_env(hook)

        process = Process.new(hook.command, shell: true,
          input: :pipe, output: stdout, error: stderr, chdir: cwd, env: env)
        process.input << json
        process.input.close

        wait_ch = Channel(Process::Status).new
        spawn { wait_ch.send(process.wait) }

        select
        when status = wait_ch.receive
          result_from_exit(status.exit_code, stdout.to_s, stderr.to_s)
        when timeout(timeout.seconds)
          kill_process(process, wait_ch)
          HookResult.new(stdout: stdout.to_s, stderr: stderr.to_s, timed_out: true)
        end
      rescue ex
        HookResult.new(stdout: "", stderr: ex.message.to_s)
      end

      # Graceful shutdown: SIGTERM → grace period → SIGKILL, always reaping
      # the zombie so the wait fiber finishes cleanly.
      private def kill_process(process : Process, wait_ch : Channel(Process::Status)) : Nil
        process.terminate rescue nil
        select
        when wait_ch.receive
          nil
        when timeout(KILL_GRACE_MS.milliseconds)
          ProcessPort.default.force_kill(process)
          wait_ch.receive rescue nil
        end
      end

      private def hook_env(hook : HookDef) : Hash(String, String)?
        return nil unless env_override = hook.env
        env = ENV.to_h
        env_override.each { |k, v| env[k] = v }
        env
      end

      private def result_from_exit(exit_code : Int32, stdout : String, stderr : String) : HookResult
        # Exit code 2 = explicit block.
        if exit_code == 2
          message = stderr.strip
          return HookResult.new(
            action: "block",
            message: message,
            reason: message,
            stdout: stdout,
            stderr: stderr,
            exit_code: exit_code,
          )
        end

        # Exit code 0 with structured JSON output may also block.
        if exit_code == 0
          structured = parse_structured(stdout)
          if structured && structured.block?
            return HookResult.new(
              action: "block",
              message: structured.message,
              reason: structured.reason,
              stdout: stdout,
              stderr: stderr,
              exit_code: exit_code,
            )
          end
          return HookResult.new(
            message: structured.try(&.message),
            stdout: stdout,
            stderr: stderr,
            exit_code: exit_code,
          )
        end

        HookResult.new(stdout: stdout, stderr: stderr, exit_code: exit_code)
      end

      private struct StructuredOutput
        getter? block : Bool
        getter message : String?
        getter reason : String?

        def initialize(@block : Bool, @message : String?, @reason : String?)
        end
      end

      private def parse_structured(stdout : String) : StructuredOutput?
        text = stdout.strip
        return nil if text.empty?

        json = JSON.parse(text) rescue return nil
        obj = json.as_h?

        message = obj.try &.["message"]?.try(&.as_s?)
        specific = obj.try &.["hookSpecificOutput"]?.try(&.as_h?)

        if specific
          specific_msg = specific["message"]?.try(&.as_s?) || message
          decision = specific["permissionDecision"]?.try(&.as_s?)
          reason = specific["permissionDecisionReason"]?.try(&.as_s?)
          if decision == "deny"
            return StructuredOutput.new(true, specific_msg, reason)
          end
          return StructuredOutput.new(false, specific_msg, reason)
        end

        nil
      end
    end
  end
end
