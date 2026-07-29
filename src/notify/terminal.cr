module Hcode
  module Notify
    # OSC 9 payload length cap — mirrors MAX_TERMINAL_NOTIFICATION_MESSAGE_LENGTH
    # in apps/kimi-code/src/tui/constant/terminal.ts.
    MAX_MESSAGE_LENGTH = 200

    # Terminal desktop-notification channel: OSC 9 on capable terminals, BEL
    # fallback elsewhere, wrapped in a tmux DCS passthrough when inside tmux.
    # Faithful port of apps/kimi-code/src/tui/utils/terminal-notification.ts.
    class TerminalChannel
      @written : Set(String) = Set(String).new
      @condition : String    # "unfocused" | "always"
      @output : IO
      @supports_osc9 : Bool
      @inside_tmux : Bool
      @focused : Bool = true

      def initialize(@output : IO = STDOUT, @condition : String = "unfocused",
                     @supports_osc9 : Bool = TerminalChannel.supports_osc9?,
                     @inside_tmux : Bool = TerminalChannel.inside_tmux?)
      end

      # Toggle focus tracking; the TUI updates this from focus-reporting escapes.
      def focused=(value : Bool) : Nil
        @focused = value
      end

      # Deliver a transition. `key` de-dupes so a repeated approval for the same
      # tool doesn't spam (mirrors notificationKeys in TS).
      def notify(key : String, title : String, body : String = "") : Nil
        return if @condition == "unfocused" && @focused
        return if @written.includes?(key)
        @written.add(key)

        message = TerminalChannel.format(title, body)
        return if message.empty?

        TerminalChannel.build_sequences(message, @supports_osc9, @inside_tmux).each do |seq|
          @output << seq
        end
        @output.flush
      end

      # --- pure helpers (testable without an IO) ---

      def self.format(title : String, body : String) : String
        t = sanitize(title)
        b = sanitize(body)
        message = (!t.empty? && !b.empty?) ? "#{t}: #{b}" : (!t.empty? ? t : b)
        message[0, Math.min(message.size, MAX_MESSAGE_LENGTH)]
      end

      # Build the OSC/BEL bytes for a notification.
      #
      # - supports_osc9: emit a single OSC 9 sequence (iTerm2, WezTerm, Kitty,
      #   Ghostty, Warp).
      # - otherwise: fall back to a bare BEL so the user still gets the bell.
      #
      # When inside tmux and emitting OSC 9, wrap in a DCS passthrough and
      # double any ESC bytes inside the payload, otherwise tmux swallows it.
      # BEL passes through tmux unchanged, so no wrap is needed there.
      def self.build_sequences(message : String, supports_osc9 : Bool, inside_tmux : Bool) : Array(String)
        return [] of String if message.empty?
        return ["\a"] unless supports_osc9 # BEL

        osc9 = "\e]9;#{message}\a"
        return [osc9] unless inside_tmux

        escaped = osc9.gsub("\e", "\e\e")
        ["\ePtmux;#{escaped}\e\\"]
      end

      # Best-effort OSC 9 detection from env vars. Conservative because BEL is
      # safe everywhere, while OSC 9 to a terminal that doesn't grok it prints
      # escape garbage.
      def self.supports_osc9?(env = ENV) : Bool
        case env["TERM_PROGRAM"]?
        when "iTerm.app", "WezTerm", "ghostty", "WarpTerminal"
          true
        else
          case env["TERM"]?
          when "xterm-kitty", "xterm-ghostty"
            true
          else
            false
          end
        end
      end

      def self.inside_tmux?(env = ENV) : Bool
        (v = env["TMUX"]?) ? !v.empty? : false
      end

      # Replace control chars with a space, collapse runs of whitespace, trim.
      private def self.sanitize(value : String) : String
        cleaned = String.build do |buf|
          value.each_char do |ch|
            code = ch.ord
            if (0x00..0x1f).includes?(code) || (0x7f..0x9f).includes?(code)
              buf << ' '
            else
              buf << ch
            end
          end
        end
        cleaned.gsub(/\s+/, " ").strip
      end
    end
  end
end
