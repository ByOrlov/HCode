module Kimi
  module Context
    # Raised when an undo request cannot be fully satisfied — either it
    # would cross a compaction boundary, or there are not enough undoable
    # user messages left. Mirrors the TS `undo_limit` error code.
    class UndoLimitError < Exception
      getter requested : Int32
      getter removed : Int32
      getter? stopped_at_compaction : Bool

      def initialize(@requested : Int32, @removed : Int32, @stopped_at_compaction : Bool)
        boundary = @stopped_at_compaction ? " (stopped at compaction boundary)" : ""
        super("Cannot undo #{requested} prompt(s); only #{removed} could be undone#{boundary}.")
      end
    end

    # Result of an undo operation: how many user prompts were removed and
    # whether the walk stopped at a compaction boundary.
    struct UndoResult
      property removed_user_count : Int32
      property? stopped_at_boundary : Bool

      def initialize(@removed_user_count : Int32, @stopped_at_boundary : Bool)
      end
    end

    # Walks backward through a Context::Memory, removing messages until
    # `count` real user prompts have been undone. Injection-origin messages
    # are skipped (left in place) — they are system bookkeeping, not user
    # turns. The walk STOPs at a compaction-summary boundary: once a
    # summary replaces history there is nothing earlier to restore.
    #
    # Ref: `packages/agent-core/src/agent/context/index.ts:253` (undo).
    module Undo
      # Perform the undo in place on `memory`. Always removes as many
      # messages as it can (best effort). Raises `UndoLimitError` when the
      # request could not be fully satisfied (hit a compaction boundary or
      # ran out of user messages), so the caller can decide whether to
      # surface the partial result to the user.
      def self.undo!(memory : Memory, count : Int32) : UndoResult
        return UndoResult.new(0, false) if count <= 0
        return UndoResult.new(0, false) if memory.history.empty?

        history = memory.history
        removed_user_count = 0
        stopped_at_boundary = false

        i = history.size - 1
        while i >= 0
          cm = history[i]

          # Injection-origin messages are skipped, not removed: they are
          # system reminders / bookkeeping, not part of a user turn.
          if cm.origin.injection?
            i -= 1
            next
          end

          # A compaction summary is an irreversible boundary — there is
          # no earlier history to restore, so stop here.
          if cm.origin.compaction_summary?
            stopped_at_boundary = true
            break
          end

          history.delete_at(i)

          if cm.message.role == "user" && cm.origin.normal?
            removed_user_count += 1
            break if removed_user_count >= count
          end

          i -= 1
        end

        memory.recalculate_token_count
        UndoResult.new(removed_user_count, stopped_at_boundary)
      end

      # Undo and raise UndoLimitError if the request was only partially
      # satisfiable. Use this from the `/undo` command path where a partial
      # undo should be reported as an error.
      def self.undo_or_raise!(memory : Memory, count : Int32) : UndoResult
        result = undo!(memory, count)
        if result.stopped_at_boundary? || result.removed_user_count < count
          raise UndoLimitError.new(count, result.removed_user_count, result.stopped_at_boundary?)
        end
        result
      end
    end
  end
end
