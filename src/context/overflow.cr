module Kimi
  module Context
    # Recovery from context-overflow conditions.
    #
    # Two overflow paths, mirroring the TS `turn-step.ts` recovery:
    #
    #   Path A (media too large, HTTP 413):
    #     normal → media-degraded → media-stripped → compact
    #     Each projection is tried at most once per turn.
    #
    #   Path B (token-count overflow, ≥ 90% of max context):
    #     trigger compaction (LLM summarises old history).
    #
    # Because kimi.cr currently has no image/media support, messages are
    # text-only and Path A collapses straight to compaction — there is no
    # media to degrade or strip. The projection state machine is still
    # wired so adding media later needs no changes here.
    #
    # Ref: `packages/agent-core/src/loop/turn-step.ts:190-315`.
    module Overflow
      enum Projection
        # No projection applied — send messages verbatim.
        Normal
        # Compress media (downscale images) before resending.
        MediaDegraded
        # Replace every media part with a text marker, keeping text intact.
        MediaStripped
      end

      enum Action
        # Resend with media degraded.
        RetryDegraded
        # Resend with all media stripped to text markers.
        RetryStripped
        # Summarise old history and retry with the compacted context.
        Compact
        # No recovery left — propagate the original error.
        Fail
      end

      # State carried across one turn's steps so recovery does not repeat a
      # projection it has already attempted. Reset at the start of each turn.
      class Recovery
        property projection : Projection = Projection::Normal
        property? media_degraded_used : Bool = false
        property? media_stripped_used : Bool = false
        property? compaction_used : Bool = false
        # When a 413 reveals the real context cap, record it so the
        # session can re-tune its budget instead of guessing.
        property learned_context_limit : Int32? = nil

        def reset : Nil
          @projection = Projection::Normal
          @media_degraded_used = false
          @media_stripped_used = false
          @compaction_used = false
          @learned_context_limit = nil
        end
      end

      # Is the given error a "request body too large" 413?
      def self.request_too_large?(error : Exception) : Bool
        error.is_a?(LLM::ApiError) && error.status_code == 413
      end

      # Token-count overflow: the estimated context size has crossed the
      # 90% threshold of the configured (or learned) context window.
      def self.token_overflow?(memory : Memory) : Bool
        memory.near_limit?
      end

      # Does the context carry any media parts? Today messages are text-only,
      # so this is always false. When ReadMedia lands, swap in a real scan.
      def self.has_media?(memory : Memory) : Bool
        false
      end

      # Decide the next recovery action for a 413 given what has been tried.
      #
      # With no media present, degrading/stripping cannot shrink the request,
      # so the state machine skips straight to compaction (and then to Fail).
      def self.recover_from_413(recovery : Recovery, has_media : Bool = false) : Action
        unless has_media
          return Action::Fail if recovery.compaction_used?
          recovery.compaction_used = true
          return Action::Compact
        end

        case recovery.projection
        in Projection::Normal
          recovery.projection = Projection::MediaDegraded
          recovery.media_degraded_used = true
          Action::RetryDegraded
        in Projection::MediaDegraded
          recovery.projection = Projection::MediaStripped
          recovery.media_stripped_used = true
          Action::RetryStripped
        in Projection::MediaStripped
          return Action::Fail if recovery.compaction_used?
          recovery.compaction_used = true
          Action::Compact
        end
      end

      # Extract a real context-token limit from a 413 / quota error body,
      # if the provider included one. Moonshot and most OpenAI-compatible
      # APIs echo the cap inside the error message.
      def self.parse_context_limit(error : LLM::ApiError) : Int32?
        body = error.message.to_s
        patterns = [
          /context[^0-9]{0,12}(\d{4,})/i,
          /maximum[^0-9]{0,12}(\d{4,})/i,
          /max[_\s-]?tokens?[^0-9]{0,12}(\d{4,})/i,
          /limit[^0-9]{0,12}(\d{4,})/i,
        ]
        patterns.each do |re|
          if m = body.match(re)
            n = m[1].to_i?
            return n if n && n > 0
          end
        end
        nil
      end

      # Apply a learned context limit to the session, so subsequent steps
      # budget against the real cap instead of the configured default.
      def self.apply_learned_limit!(memory : Memory, recovery : Recovery, error : LLM::ApiError) : Nil
        return if recovery.learned_context_limit
        if limit = parse_context_limit(error)
          recovery.learned_context_limit = limit
          memory.max_context_tokens = limit if limit < memory.max_context_tokens
        end
      end
    end
  end
end
