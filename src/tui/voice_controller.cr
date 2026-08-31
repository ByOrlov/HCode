module H2code
  module TUI
    # Voice-message recording driven by the local h2voice server (see
    # VOICE_PROTOCOL.md). Ctrl+R or a double-Space press starts a recording
    # session: the TUI shows a pending "RECORDING" tool entry (active zone,
    # animated), while a detached fiber consumes the server's SSE stream.
    # Ctrl+R, Escape or Space stops the capture; the server transcribes and
    # the final text is delivered as a normal user
    # message (queued when the agent is busy, sent immediately when idle).
    module VoiceController
      # Tool name shown in the transcript for a voice recording.
      RECORDING_TOOL = "RECORDING"

      # True while a voice session is connecting, recording or transcribing —
      # drives the 80 ms animation tick so the timer/level meter keeps moving
      # even when the agent itself is idle.
      def voice_active? : Bool
        !@voice_msg_idx.nil?
      end

      def voice_recording? : Bool
        @voice_recording && voice_active?
      end

      # Ctrl+R / Esc / Space handler. Toggle: start when idle, stop-and-
      # transcribe while a session is in flight (ignored during the stop→result
      # gap). Public so embedded drivers and specs can drive the same action as
      # the key.
      def toggle_voice_recording : Nil
        if voice_active?
          stop_voice_recording
        else
          start_voice_recording
        end
      end

      private def voice_config : Config::TranscriptionConfig?
        cfg = @app_config
        return cfg.transcription if cfg
        nil
      end

      # Advice shown when a recording cannot even start: with H2 Voice
      # absent from the system, point at the install page; when it is
      # installed but the config is missing/disabled, at the config section.
      private def voice_missing_hint : String
        if @voice_presence.installed?
          "Voice messages are disabled. Enable the [transcription] section in ~/.h2code/config.json"
        else
          "H2 Voice is not installed. Install H2 Voice to recognize voice: #{Transcription::VoicePresencePort::INSTALL_URL}"
        end
      end

      # Socket-connect failure during record_start: distinguish "server not
      # running" (installed but stopped) from "H2 Voice not installed at
      # all" — the latter gets the install advice + link.
      private def voice_socket_error(client : Transcription::Client, ex : IO::Error) : String
        if @voice_presence.installed?
          "Voice server unavailable at #{client.socket_path} — is h2voice running? (#{ex.message})"
        else
          "H2 Voice is not installed. Install H2 Voice to recognize voice: #{Transcription::VoicePresencePort::INSTALL_URL}"
        end
      end

      private def start_voice_recording : Nil
        cfg = voice_config
        unless cfg && cfg.enabled?
          emit_to_log(Message.new("error", voice_missing_hint))
          invalidate_log_cache!
          @dirty = true
          return
        end

        client = Transcription::Client.from_config(cfg)
        started_at = Time.monotonic
        msg = Message.new("tool", "")
        msg.tool_call_id = "voice-#{Time.utc.to_unix_ms}"
        msg.tool_name = RECORDING_TOOL
        emit_to_log(msg)
        @voice_msg_idx = @messages.size - 1
        @voice_recording = false
        @voice_level = 0.0
        @voice_started_at = started_at
        @voice_engine = ""
        invalidate_log_cache!
        @dirty = true

        spawn do
          begin
            client.record_start(cfg.language, cfg.engine) { |evt| handle_voice_event(evt) }
          rescue ex : IO::Error
            voice_finish(error: voice_socket_error(client, ex))
          rescue ex : Exception
            ExceptionHandler.report(ex, "voice recording")
            voice_finish(error: "Voice recording failed: #{ex.message}")
          end
        end

        # Auto-stop watchdog: cap the recording at max_duration_sec.
        if max = cfg.max_duration_sec
          spawn do
            sleep ({max, 1}.max).seconds
            # Only fire when this exact session is still recording (the timer
            # values double as session tokens: a new session gets a new one).
            stop_voice_recording if @voice_recording && @voice_started_at == started_at
          end
        end
      end

      private def stop_voice_recording : Nil
        return unless voice_recording?
        cfg = voice_config
        client = Transcription::Client.from_config(cfg) if cfg
        @voice_recording = false
        @dirty = true
        spawn do
          begin
            client.try(&.record_stop)
          rescue ex : IO::Error
            # The SSE stream will surface the failure; stop is best-effort.
          end
        end
      end

      # SSE event pump. Runs on the recording fiber — only touches shared App
      # state, same as any other event fiber (single-threaded scheduler).
      private def handle_voice_event(evt : Transcription::RecordEvent) : Nil
        case evt.type
        when "started"
          @voice_recording = true
          @voice_started_at = Time.monotonic
          @dirty = true
        when "level"
          @voice_level = evt.rms
          @dirty = true
        when "transcribing"
          @voice_recording = false
          @voice_engine = evt.engine
          @dirty = true
        when "result"
          duration = evt.duration_ms > 0 ? evt.duration_ms : voice_elapsed_ms
          meta = {"duration_ms" => duration, "engine" => evt.engine,
                  "language" => evt.language}.to_json
          voice_finish(result: evt.text, meta: meta)
          deliver_transcription(evt.text)
        when "error"
          voice_finish(error: "#{evt.code}: #{evt.message}")
        end
      end

      # Terminal path for the voice tool message: attach the result (or the
      # error) so it migrates from the active zone into the log.
      private def voice_finish(*, result : String? = nil, meta : String? = nil,
                               error : String? = nil) : Nil
        @voice_recording = false
        @voice_level = 0.0
        idx = @voice_msg_idx
        if idx && (msg = @messages[idx]?)
          if err = error
            msg.is_error = true
            msg.tool_result = err
            msg.tool_args = nil
          else
            msg.tool_result = result.to_s
            msg.tool_args = meta
          end
          @messages[idx] = msg
        end
        @voice_msg_idx = nil
        invalidate_log_cache!
        @dirty = true
        render_now
      end

      # Feed the transcription into the normal message path: queued while the
      # agent is mid-turn, sent immediately when idle (same as typed input).
      private def deliver_transcription(text : String) : Nil
        submit_message(text) unless text.strip.empty?
      end

      # Milliseconds since the current recording started (monotonic clock).
      def voice_elapsed_ms : Int64
        return 0_i64 unless start = @voice_started_at
        ((Time.monotonic - start).total_milliseconds).to_i64.clamp(0_i64..)
      end
    end
  end
end
