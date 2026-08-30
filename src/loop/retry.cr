module H2code
  module Loop
    # Retry policy for transient LLM failures (429 rate limits, 5xx server
    # errors, network timeouts). Extracted from the inline retry loop in
    # `Agent#execute_step` so the delay calculation and retry decision are
    # unit-testable.
    #
    # Mirrors the backoff shape used by the TS agent-core step runner:
    # exponential backoff (2^n seconds) capped at 30s, up to `max_retries`
    # attempts. Non-retryable errors (`ApiError` with `retryable? == false`,
    # e.g. 401/403 auth or 400 bad request) short-circuit immediately.
    class RetryPolicy
      getter max_retries : Int32
      getter base_delay : Int32
      getter max_delay : Int32

      def initialize(@max_retries : Int32 = 3,
                     @base_delay : Int32 = 2,
                     @max_delay : Int32 = 30)
      end

      # Returns the delay (seconds) for the given 1-based attempt number, or
      # nil if retries are exhausted. Attempt 1 is the first retry after the
      # initial failure.
      def delay_for(attempt : Int32) : Int32?
        return nil if attempt > @max_retries
        {@base_delay ** attempt, @max_delay}.min
      end

      # True iff the error is worth retrying (transient). Auth/quota/bad-
      # request errors are not — backing off cannot fix them.
      def retryable?(error : Exception) : Bool
        case error
        when LLM::ApiError
          error.retryable?
        when Loop::UserCancellationError
          false
        else
          true # network errors, timeouts
        end
      end
    end
  end
end
