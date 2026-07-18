require "./tool_batch"

module Hcode
  module Loop
    alias StepResult = LLM::StepResult
    alias TurnResult = LLM::TurnResult

    class Agent
      getter provider : LLM::Provider
      getter context : Context::Memory
      getter tools : Tools::Registry
      getter permission : Permission::Manager
      property abort_controller : AbortController = AbortController.new

      @dedup : DedupTracker = DedupTracker.new
      @overflow_recovery : Context::Overflow::Recovery = Context::Overflow::Recovery.new
      @max_steps : Int32 = 100

      def initialize(@provider : LLM::Provider,
                     @context : Context::Memory,
                     @tools : Tools::Registry,
                     @permission : Permission::Manager)
      end

      def run_turn(prompt : String, system_prompt : String? = nil,
                   &on_event : Event ->) : TurnResult
        # A previous turn may have been cancelled; clear the flag so this turn
        # can run. Without this, interrupting once would poison every later turn.
        @abort_controller.reset!
        # Fresh overflow recovery for this turn — each projection/compaction
        # is tried at most once per turn.
        @overflow_recovery.reset

        @context.add_user(prompt)
        on_event.call(Event.user_message(prompt))

        total_usage = LLM::Usage.new
        steps = 0
        sys_prompt = system_prompt

        loop do
          @abort_controller.throw_if_aborted!

          if steps >= @max_steps
            on_event.call(Event.error("Max steps (#{@max_steps}) exceeded"))
            return TurnResult.new("max_steps", steps, total_usage)
          end

          steps += 1
          on_event.call(Event.step_begin(steps))

          if @context.near_limit? && sys_prompt
            on_event.call(Event.info("Context near limit, triggering compaction..."))
            sys_prompt = trigger_compaction(sys_prompt, on_event)
          end

          @context.prune_injections
          inject_step_reminders(steps)

          step_result = execute_step(sys_prompt, on_event)

          # The provider's usage object carries the authoritative context
          # fill; feed it back into memory so the percent/count reflect the
          # real window usage instead of the local heuristic estimate.
          @context.update_token_count_from_usage(
            step_result.usage.prompt_tokens,
            step_result.usage.completion_tokens,
          )

          total_usage = total_usage + step_result.usage
          on_event.call(Event.step_end(steps, step_result.usage))

          unless step_result.text.empty? && step_result.tool_calls.empty?
            @context.add_assistant(step_result.text, step_result.tool_calls)
            on_event.call(Event.assistant_text(step_result.text)) unless step_result.text.empty?
          end

          if step_result.tool_use?
            tool_results = run_tool_batch(step_result.tool_calls, on_event)
          else
            return TurnResult.new(step_result.stop_reason, steps, total_usage)
          end
        end
      end

      def cancel : Nil
        @abort_controller.abort("user requested cancel")
      end

      # Hot-swap the LLM backend so the `/provider` selector can switch
      # providers at runtime without restarting the process. Safe to call
      # between turns; a turn in flight continues against the old provider.
      def swap_provider!(provider : LLM::Provider) : Nil
        @provider = provider
      end

      def trigger_compaction_tui(system_prompt : String?, &on_event : Event ->) : Nil
        trigger_compaction(system_prompt || "", on_event)
      end

      private def execute_step(system_prompt : String?, on_event : Event ->) : StepResult
        retry_count = 0
        max_retries = 3

        loop do
          # Keep the provider's completion-budget clamp in sync with the real
          # context size for this step (it clamps max_completion_tokens against
          # the remaining window). Re-read every iteration because compaction
          # may have shrunk the context between attempts.
          @provider.used_context_tokens = @context.token_count

          messages = @context.messages
          tool_defs = @tools.definitions

          if ENV["HCODE_DEBUG"]?
            STDERR.puts "[debug] Last 3 messages:"
            messages.last(3).each_with_index(1) do |msg, i|
              STDERR.puts "[debug]   msg #{i}: role=#{msg.role} content=#{msg.content.to_s[0...80].inspect} " \
                          "tool_calls=#{msg.tool_calls.try(&.map(&.id).inspect)} " \
                          "tool_call_id=#{msg.tool_call_id.inspect}"
            end
          end

          begin
            return @provider.chat(messages, tool_defs, system_prompt,
              aborted?: ->{ @abort_controller.aborted? }) do |part|
              case part
              when LLM::TextPart
                on_event.call(Event.text_delta(part.text))
              when LLM::ThinkPart
                on_event.call(Event.thinking_delta(part.text))
              when LLM::ToolCallPart
                on_event.call(Event.tool_call_delta(part.id, part.name, part.arguments))
              end

              # Yield so the TUI's main loop fiber can render streaming updates
              # (thinking preview, assistant text) between parts. Without this,
              # a fast provider or mock can process every part in one burst and
              # the user never sees the live streaming content.
              Fiber.yield
            end
          rescue ex : UserCancellationError
            raise ex
          rescue ex
            # If the user cancelled (incl. mid-connection), surface that and
            # never retry the partial/aborted request.
            @abort_controller.throw_if_aborted!

            # 413 (request too large) has its own recovery path: degrade →
            # strip → compact. It is non-retryable by the generic backoff,
            # so intercept it before the fail-fast branch.
            if ex.is_a?(LLM::ApiError) && Context::Overflow.request_too_large?(ex)
              Context::Overflow.apply_learned_limit!(@context, @overflow_recovery, ex)
              action = Context::Overflow.recover_from_413(@overflow_recovery, Context::Overflow.has_media?(@context))
              case action
              in Context::Overflow::Action::Compact
                on_event.call(Event.info("Context too large for the model; compacting..."))
                trigger_compaction(system_prompt || "", on_event)
                next # rebuild messages from the compacted context and retry
              in Context::Overflow::Action::RetryDegraded, Context::Overflow::Action::RetryStripped
                # No media projection implemented yet — fall through to retry
                # with the (unchanged) messages. Kept for forward-compat.
                next
              in Context::Overflow::Action::Fail
                on_event.call(Event.info("Context still too large after compaction; giving up."))
                raise ex
              end
            end

            # Non-retryable client errors (auth, quota, bad request, ...) fail
            # fast — backing off cannot fix them.
            if ex.is_a?(LLM::ApiError) && !ex.retryable?
              raise ex
            end
            retry_count += 1
            if retry_count <= max_retries
              delay = {2 ** retry_count, 30}.min
              on_event.call(Event.info("Retrying in #{delay}s... (#{ex.message})"))
              sleep delay.seconds
            else
              raise "LLM call failed after #{max_retries} retries: #{ex.message}"
            end
          end
        end
      end

      private def run_tool_batch(tool_calls : Array(LLM::ToolCall),
                                 on_event : Event ->) : Array(LLM::Message)
        if ENV["HCODE_DEBUG"]?
          tool_calls.each do |tc|
            STDERR.puts "[debug] ToolCall: id=#{tc.id.inspect} name=#{tc.name} args=#{tc.arguments[0...100]}"
          end
        end

        ToolBatch.new(
          registry: @tools,
          permission: @permission,
          dedup: @dedup,
          abort_controller: @abort_controller,
          context: @context,
        ).run(tool_calls, &on_event)
      end

      private def inject_step_reminders(steps : Int32) : Nil
        todo_tool = @tools.get("TodoList")
        return unless todo_tool.is_a?(Tools::TodoList)

        pending = todo_tool.pending_count
        return if pending == 0

        reminder = String.build do |s|
          s << "<system-reminder>\n"
          s << "You have #{pending} pending todo item(s). "
          s << "Review the list and update it: mark completed items as done, "
          s << "set the next item to in_progress, and add new items for any "
          s << "work you discover. Keep the list current.\n"
          s << "NEVER mention this reminder to the user.\n"
          s << "</system-reminder>"
        end

        @context.add_injection(reminder)
      end

      private def trigger_compaction(system_prompt : String, on_event : Event ->) : String
        old_messages = @context.history

        kept_count = Math.min(6, old_messages.size)
        kept = old_messages[-kept_count..] || [] of Context::ContextMessage

        summary_prompt = "Summarize the following conversation so far, preserving key context: "
        summary_messages = [
          LLM::Message.user(summary_prompt + old_messages.map(&.message.content.to_s).join("\n")),
        ]

        begin
          # Compaction summarises a near-full context, so the live window is
          # almost exhausted. Reset the budget clamp so the summary request is
          # not starved into a tiny output cap by the large used-context value.
          @provider.used_context_tokens = 0
          summary_result = @provider.chat(summary_messages, nil, nil) do |part|
          end
          summary = summary_result.text
        rescue
          summary = "[Compaction failed — keeping full history]"
          kept = old_messages
        end

        @context.apply_compaction(summary, kept)
        on_event.call(Event.info("Context compacted (#{old_messages.size} → #{kept.size} messages)"))

        system_prompt
      end
    end
  end
end
