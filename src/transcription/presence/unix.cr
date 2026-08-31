{% skip_file if flag?(:win32) %}

module H2code
  module Transcription
    # POSIX adapter: an `h2voice` executable anywhere on $PATH, or the
    # ~/.h2voice data directory (created by the server on first run).
    class UnixVoicePresence < VoicePresencePort
      def installed? : Bool
        voice_dir_present? || executable_on_path?(["h2voice"])
      end
    end
  end
end
