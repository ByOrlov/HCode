module Hcode
  module Context
    # Context summarization when the conversation nears the context window.
    #
    # Extracted from `Agent#trigger_compaction` so the logic is unit-testable
    # in isolation: given a provider + a `Context::Memory`, it produces a
    # summary, applies it, and reports token savings. Mirrors TS
    # `packages/agent-core/src/loop/compaction/full.ts`.
    class Compaction
      # Number of recent messages kept verbatim after compaction. Older
      # history is folded into the summary. Matches the TS default.
      DEFAULT_KEPT_COUNT = 6

      getter provider : LLM::Provider
      getter context : Context::Memory
      getter kept_count : Int32

      def initialize(@provider : LLM::Provider,
                     @context : Context::Memory,
                     @kept_count : Int32 = DEFAULT_KEPT_COUNT)
      end

      # Summarize the current history and replace it with the summary +
      # `kept_count` recent messages. Returns the summary text (useful for
      # the caller's event payload and persistence).
      #
      # On cancellation or provider failure the full history is retained and
      # the returned summary reflects that (mirrors the inline version).
      def compact(&on_part : LLM::MessagePart ->) : CompactionResult
        old_messages = @context.history
        tokens_before = @context.token_count

        kept_n = Math.min(@kept_count, old_messages.size)
        kept = kept_n > 0 ? old_messages[-kept_n..] : [] of ContextMessage

        summary_prompt = "Summarize the following conversation so far, preserving key context: "
        summary_messages = [
          LLM::Message.user(summary_prompt + old_messages.map(&.message.content.to_s).join("\n")),
        ]

        # Compaction summarises a near-full context, so the live window is
        # almost exhausted. Reset the budget clamp so the summary request is
        # not starved into a tiny output cap by the large used-context value.
        @provider.used_context_tokens = 0
        summary = ""
        status : CompactionStatus = CompactionStatus::Completed

        begin
          summary_result = @provider.chat(summary_messages, nil, nil) do |part|
            on_part.call(part)
          end
          summary = summary_result.text
        rescue ex : Loop::UserCancellationError
          status = CompactionStatus::Cancelled
          summary = "[Compaction cancelled — keeping full history]"
          kept = old_messages
        rescue
          status = CompactionStatus::Failed
          summary = "[Compaction failed — keeping full history]"
          kept = old_messages
        end

        @context.apply_compaction(summary, kept)
        tokens_after = @context.token_count

        CompactionResult.new(
          status: status,
          summary: summary,
          tokens_before: tokens_before,
          tokens_after: tokens_after,
          messages_before: old_messages.size,
          messages_after: kept.size,
        )
      end
    end

    enum CompactionStatus
      Completed
      Cancelled
      Failed
    end

    struct CompactionResult
      getter status : CompactionStatus
      getter summary : String
      getter tokens_before : Int32
      getter tokens_after : Int32
      getter messages_before : Int32
      getter messages_after : Int32

      def initialize(@status : CompactionStatus,
                     @summary : String,
                     @tokens_before : Int32,
                     @tokens_after : Int32,
                     @messages_before : Int32,
                     @messages_after : Int32)
      end

      def cancelled? : Bool
        @status == CompactionStatus::Cancelled
      end

      def failed? : Bool
        @status == CompactionStatus::Failed
      end

      def completed? : Bool
        @status == CompactionStatus::Completed
      end
    end
  end
end
