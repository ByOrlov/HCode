module Hcode
  module Loop
    alias ToolResult = Tools::ToolResult

    class AbortController
      @aborted : Bool = false
      @reason : String? = nil

      getter? aborted : Bool

      def abort(reason : String = "cancelled") : Nil
        @aborted = true
        @reason = reason
      end

      def reset! : Nil
        @aborted = false
        @reason = nil
      end

      def reason : String?
        @reason
      end

      def throw_if_aborted! : Nil
        if @aborted
          raise UserCancellationError.new(@reason || "cancelled")
        end
      end
    end

    class UserCancellationError < Exception
      property reason : String

      def initialize(@reason : String = "cancelled")
        super("User cancelled: #{@reason}")
      end
    end

    # Raised when the LLM call fails after exhausting all retries due to a
    # network error (broken pipe, connection reset, timeout). Distinct from
    # `UserCancellationError` so the TUI can render a different message.
    class NetworkFailureError < Exception
    end

    GRACE_TIMEOUT_SECONDS = 2
    ABORT_POLL_INTERVAL   = 100.milliseconds

    # Execute a tool with abort-aware grace timeout.
    #
    # During normal execution NO wall-clock timer runs — the tool runs to
    # completion regardless of duration. Only when the abort controller fires
    # is a grace period started; if the tool doesn't finish within it, a
    # synthetic error result is returned (the orphan fiber keeps running since
    # Crystal cannot kill fibers). This mirrors the JS
    # `raceExecuteWithGraceTimeout` semantics where the timer is armed on
    # `signal.addEventListener('abort', …)`, not at tool start.
    #
    # Unexpected (non-cancellation) exceptions from the tool are captured and
    # re-raised on the caller's fiber so the loop-level interceptor can surface
    # them to the UI, instead of being silently swallowed as error results.
    def self.execute_tool(abort_controller : AbortController,
                          grace_timeout : Time::Span = GRACE_TIMEOUT_SECONDS.seconds,
                          &block : -> ToolResult) : ToolResult
      # Internal channel payload: either a result or an exception to re-raise.
      channel = Channel({ToolResult?, Exception?}).new

      spawn do
        result, exc = begin
          {block.call, nil}
        rescue ex : UserCancellationError
          {Tools::ToolResult.error("Cancelled: #{ex.reason}"), nil}
        rescue ex
          {nil, ex}
        end

        begin
          channel.send({result, exc})
        rescue Channel::ClosedError
        end
      end

      handle = ->(payload : {ToolResult?, Exception?}) : ToolResult do
        if exc = payload[1]
          raise exc
        end
        payload[0] || Tools::ToolResult.error("No result")
      end

      if abort_controller.aborted?
        select
        when payload = channel.receive
          return handle.call(payload)
        when timeout(grace_timeout)
          channel.close
          return Tools::ToolResult.error(
            "[Execution did not finish within #{grace_timeout.total_seconds.to_i}s grace period after abort]"
          )
        end
      else
        loop do
          select
          when payload = channel.receive
            return handle.call(payload)
          when timeout(ABORT_POLL_INTERVAL)
            if abort_controller.aborted?
              select
              when payload = channel.receive
                return handle.call(payload)
              when timeout(grace_timeout)
                channel.close
                return Tools::ToolResult.error(
                  "[Execution did not finish within #{grace_timeout.total_seconds.to_i}s grace period after abort]"
                )
              end
            end
          end
        end
      end
    end
  end
end
