{% skip_file unless flag?(:win32) %}

module H2code
  module Transcription
    # Windows adapter: `h2voice.exe`/`h2voice.bat` anywhere on %PATH%, or
    # the %USERPROFILE%\.h2voice data directory.
    class Win32VoicePresence < VoicePresencePort
      def installed? : Bool
        voice_dir_present? || executable_on_path?(["h2voice.exe", "h2voice.bat"])
      end
    end
  end
end
