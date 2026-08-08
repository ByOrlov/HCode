module Hcode
  module TUI
    # Zone-balance contract for the two-zone TUI renderer.
    #
    # The screen is split into **LogZone** (append-only history from
    # `@messages`) and **ActiveZone** (repainted every frame). The render
    # invariant is: `log_lines + active_lines` must never shrink between
    # frames. When an element leaves the active zone it must push *at least
    # one* line into the log — otherwise the combined coverage drops and the
    # screen desyncs.
    #
    # This module provides the single channel through which both zones are
    # mutated:
    #
    # * `emit_to_log` — the ONLY way to add a message to the log. Replaces
    #   the scattered `@messages << … ; invalidate_log_cache!` pattern.
    # * `declare_active` / `release_active` — bracket the lifetime of a
    #   transient active-zone element. On release, if nothing was emitted to
    #   the log since the declare, a spacer line is pushed automatically.
    module Zones
      # Keys currently occupying active-zone rows (agent-state-driven only).
      @active_keys = Set(Symbol).new
      # `@messages.size` snapshot at the time each key was declared.
      @log_size_at_declare = {} of Symbol => Int32

      # The single entry point for adding content to the log zone.
      # Appends to `@messages` and invalidates the log-line cache so the
      # new entry appears on the next render. Every `@messages <<` in the
      # codebase MUST go through here.
      def emit_to_log(message : Message) : Nil
        @messages << message
        invalidate_log_cache!
      end

      # Declare that a transient element is occupying rows in the active
      # zone. Records the current log size so `release_active` can detect
      # whether anything was emitted while the element was visible.
      # Idempotent: re-declaring the same key refreshes the snapshot.
      def declare_active(key : Symbol) : Nil
        @active_keys.add(key)
        @log_size_at_declare[key] = @messages.size
      end

      # Release a transient element. If no message was emitted to the log
      # since the matching `declare_active`, a single blank "spacer" line is
      # pushed to keep the zone balance invariant. If real content was
      # emitted (even one line), nothing is added — the deficit is the
      # caller's responsibility and is expected.
      def release_active(key : Symbol) : Nil
        return unless @active_keys.includes?(key)
        @active_keys.delete(key)
        since = @log_size_at_declare.delete(key) || @messages.size
        emit_to_log(Message.new("spacer", "")) if @messages.size == since
      end
    end
  end
end
