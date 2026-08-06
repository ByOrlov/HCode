module Hcode
  module Notify
    # Fan-out + per-channel gating. Holds the optional Terminal, Player, and
    # Webhook instances and is called once per transition. Respects per-channel
    # `enabled` flags and the global master switch (off = the whole subsystem
    # is inert). `StatusTracker#transition!` calls `on_transition` directly, so
    # the agent loop itself stays unaware of channels.
    class Dispatcher
      @config : Notify::Config
      @terminal : TerminalChannel?
      @player : Player?
      @webhook : Webhook?

      def initialize(@config : Notify::Config = Notify::Config.default,
                     @terminal : TerminalChannel? = nil,
                     @player : Player? = nil,
                     @webhook : Webhook? = nil)
      end

      # Build a dispatcher from a Notify::Config, constructing only the channels
      # that are enabled. Disabled channels stay nil → no allocation/fork.
      def self.from_config(config : Notify::Config, output : IO = STDOUT) : Dispatcher
        terminal = nil
        player = nil
        webhook = nil

        if config.enabled? && config.terminal_enabled?
          terminal = TerminalChannel.new(output, config.condition)
        end
        if config.enabled? && config.sound_enabled?
          player = Player.new(
            done_path: config.sound_done,
            alert_path: config.sound_input_required,
            working_path: config.sound_working,
          )
        end
        if config.enabled? && config.webhook_enabled? && !config.webhook_url.empty?
          webhook = Webhook.new(
            url: config.webhook_url,
            method: config.webhook_method,
            headers: config.webhook_headers,
            secret: config.webhook_secret,
            timeout_ms: config.webhook_timeout_ms,
          )
        end

        new(config, terminal, player, webhook)
      end

      def on_transition(payload : Transition) : Nil
        return unless @config.enabled?

        # Terminal: only user-facing transitions (done, input_required).
        # `turn_started` is intentionally silent on the terminal channel.
        if t = @terminal
          case payload.event
          when "turn_done"
            t.notify(payload.event, payload.title, payload.body)
          when "input_required"
            t.notify(payload.event, payload.title, payload.body)
          end
        end

        # Sound: done + input_required + optional working.
        @player.try(&.play_for(payload.event))

        # Webhook: every transition the plan lists (started, done, input_required).
        case payload.event
        when "turn_started", "turn_done", "input_required"
          @webhook.try(&.fire(payload))
        end
      end
    end
  end
end
