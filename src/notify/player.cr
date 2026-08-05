module Hcode
  module Notify
    # Sound playback channel. No mature pure-Crystal audio shard exists, so this
    # is a thin cross-platform dispatcher that shells out to the OS-native
    # player. The first available command wins (probed once at init, cached).
    # Playback runs in a detached fiber — a stuck/missing player must never
    # block the agent loop.
    class Player
      @cmd : {String, Array(String)}?

      def initialize(@done_path : String = "", @alert_path : String = "",
                     @working_path : String = "",
                     probe : Bool = true,
                     os : String = Player.detect_os)
        @cmd = probe ? Player.resolve_player(os) : nil
      end

      def play_for(event : String) : Nil
        path = case event
               when "turn_done"      then @done_path
               when "input_required" then @alert_path
               when "turn_started"   then @working_path
               else                       ""
               end
        play(path) unless path.empty?
      end

      def play(path : String) : Nil
        cmd = @cmd || return
        return unless File.exists?(path)
        spawn do
          Process.run(cmd[0], args: cmd[1] + [path],
            output: Process::Redirect::Close, error: Process::Redirect::Close)
        end
      end

      # Probe the OS-native player. The first available command wins;
      # `ffplay` is the final cross-platform fallback.
      def self.resolve_player(os : String = Player.detect_os) : {String, Array(String)}?
        Player.candidates_for(os).each do |cmd|
          return cmd if command_available?(cmd[0])
        end
        nil
      end

      def self.command_available?(name : String) : Bool
        !Process.find_executable(name).nil?
      end

      # Per-OS player candidate list, most-preferred first.
      def self.candidates_for(os : String) : Array({String, Array(String)})
        case os
        when "macos"
          [{"afplay", [] of String}, {"ffplay", ["-nodisp", "-autoexit", "-loglevel", "quiet"]}]
        when "windows"
          [{"powershell", ["-c"]}, {"ffplay", ["-nodisp", "-autoexit", "-loglevel", "quiet"]}]
        else
          [
            {"pw-play", [] of String},
            {"paplay", [] of String},
            {"aplay", [] of String},
            {"ffplay", ["-nodisp", "-autoexit", "-loglevel", "quiet"]},
          ]
        end
      end

      # Runtime OS detection via uname. Falls back to "unix".
      def self.detect_os : String
        {% if flag?(:darwin) %}
          "macos"
        {% elsif flag?(:win32) %}
          "windows"
        {% else %}
          "unix"
        {% end %}
      end
    end
  end
end
