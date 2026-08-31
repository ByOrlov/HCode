require "../spec_helper"
require "../../src/tui/diff"
require "../../src/tui/app"

# Interactive h2voice mock: the /v1/record/start SSE stream stays open after
# `started`, and /v1/record/stop finishes the session by writing the
# transcribing + result events onto that stream — mirroring the real server.
class VoiceSessionMock
  property stop_requests : Int32 = 0
  @sse : UNIXSocket? = nil
  @server : UNIXServer
  @path : String

  def initialize
    @path = File.join(Dir.tempdir, "h2voice-session-#{Random::Secure.hex(6)}.sock")
    @server = UNIXServer.new(@path)
    spawn do
      while client = @server.accept?
        spawn { handle(client) }
      end
    end
  end

  def socket_path : String
    @path
  end

  def close : Nil
    @sse.try(&.close)
    @server.close rescue nil
    File.delete(@path) rescue nil
  end

  private def handle(client : UNIXSocket) : Nil
    path = read_head(client).split(' ')[1]?
    case path
    when "/v1/record/start"
      client << "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
      client << sse(%({"type":"started","sample_rate":16000}))
      client.flush
      @sse = client
    when "/v1/record/stop"
      @stop_requests += 1
      body = %({"status":"stopped","duration_ms":4200})
      client << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      client.flush
      client.close
      if sse = @sse
        sse << sse(%({"type":"transcribing","engine":"gigaam","language":"ru"}))
        sse << sse(%({"type":"result","text":"привет из теста","duration_ms":4200,"engine":"gigaam","language":"ru"}))
        sse.flush
        sse.close
      end
    end
  rescue IO::Error
  end

  private def read_head(client : UNIXSocket) : String
    String.build do |s|
      loop do
        line = client.read_line
        break if line == "\r\n" || line.empty?
        s << line << "\n"
      end
    end
  rescue IO::Error
    ""
  end

  private def sse(json : String) : String
    "data: #{json}\n\n"
  end
end

def voice_wait_until(timeout_ms = 5000, & : -> Bool) : Bool
  deadline = Time.monotonic + timeout_ms.milliseconds
  until yield
    return false if Time.monotonic > deadline
    sleep 5.milliseconds
    Fiber.yield
  end
  true
end

# Scriptable stand-in for the presence port so specs never probe the real
# filesystem (the OS adapters scan $PATH and ~/.h2voice).
class FakeVoicePresence < H2code::Transcription::VoicePresencePort
  def initialize(@installed : Bool)
  end

  def installed? : Bool
    @installed
  end
end

describe H2code::TUI::App do
  it "runs a full voice recording session via the h2voice server" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config
      submitted = [] of String
      app.run_turn_cb = ->(text : String, _persisted : Bool) do
        submitted << text
        nil
      end

      # Ctrl+R #1: session starts, pending RECORDING tool appears in the
      # active zone with the REC timer and the stop hint.
      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true
      msg = app.@messages.find { |m| m.role == "tool" && m.tool_name == "RECORDING" }
      msg.should_not be_nil
      if m = msg
        m.tool_result.should be_nil
      end
      lines, _editor_line, log_size = app.build_rendered_lines(80)
      active = lines[log_size..].map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
      active.join('\n').should contain("REC")
      active.join('\n').should contain("Ctrl+R / Esc / Space — stop and transcribe")

      # Ctrl+R #2: stop → transcribing → result. The transcription is fed
      # into the normal message path (agent idle → immediate turn), and the
      # finished entry migrates to the log zone with duration + engine.
      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
      mock.stop_requests.should eq(1)

      done = app.@messages.find { |t| t.role == "tool" && t.tool_name == "RECORDING" }
      done.should_not be_nil
      if m = done
        m.tool_result.should eq("привет из теста")
        m.is_error?.should be_false
        meta = JSON.parse(m.tool_args.to_s)
        meta["engine"].to_s.should eq("gigaam")
        meta["duration_ms"].as_i64.should eq(4200)
      end

      lines2, _editor2, log_size2 = app.build_rendered_lines(80)
      log = lines2[0...log_size2].map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
      log.join('\n').should contain("Voice message · 00:04 · gigaam")
      log.join('\n').should contain("привет из теста")

      submitted.should eq(["привет из теста"])
    ensure
      mock.close
    end
  end

  it "keeps the recording working while the agent is busy (queued transcription)" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config
      app.run_turn_cb = ->(_text : String, _persisted : Bool) { nil }

      # Simulate a busy agent: the transcription must land in the queue.
      # compaction_started flips @is_compacting + @defer_user_messages — the
      # same gates submit_message checks to decide queue-vs-immediate.
      app.on_event(H2code::Loop::Event.compaction_started)
      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true
      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true

      app.@queue.size.should eq(1)
      app.@queue[0].text.should eq("привет из теста")
      app.agent_busy?.should be_true
    ensure
      mock.close
    end
  end

  it "does not start a session when transcription is disabled" do
    app = H2code::TUI::App.new
    app.app_config = H2code::Config::Config.new
    app.voice_presence = FakeVoicePresence.new(true)
    app.toggle_voice_recording
    app.voice_active?.should be_false
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("[transcription]")
  end

  it "advises installing H2 Voice when unconfigured and absent from the system" do
    app = H2code::TUI::App.new
    app.app_config = H2code::Config::Config.new
    app.voice_presence = FakeVoicePresence.new(false)
    app.toggle_voice_recording
    app.voice_active?.should be_false
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("Install H2 Voice")
    app.@messages.last.content.should contain(H2code::Transcription::VoicePresencePort::INSTALL_URL)
  end

  it "advises installing H2 Voice when the socket is dead and H2 Voice is absent" do
    app = H2code::TUI::App.new
    config = H2code::Config::Config.new
    config.transcription = H2code::Config::TranscriptionConfig.new(
      enabled: true, socket: "/nonexistent/h2voice.sock")
    app.app_config = config
    app.voice_presence = FakeVoicePresence.new(false)
    app.toggle_voice_recording
    voice_wait_until { !app.voice_active? }.should be_true
    done = app.@messages.find { |t| t.role == "tool" && t.tool_name == "RECORDING" }
    done.should_not be_nil
    if m = done
      m.is_error?.should be_true
      (m.tool_result || "").should contain("Install H2 Voice")
      (m.tool_result || "").should contain(H2code::Transcription::VoicePresencePort::INSTALL_URL)
    end
  end

  it "starts a recording on a double-Space tap (alternative to Ctrl+R)" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config

      # First tap: not consumed (the space is typed normally), but armed.
      app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
      app.@last_space_at.should_not be_nil

      # Second tap within DOUBLE_SPACE_MS: consumed → recording starts and
      # the armed state resets.
      app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_true
      app.@last_space_at.should be_nil
      voice_wait_until { app.voice_recording? }.should be_true

      # Stop so the mock's SSE fiber finishes cleanly.
      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
    ensure
      mock.close
    end
  end

  it "keeps spaces normal when transcription is disabled" do
    app = H2code::TUI::App.new
    app.app_config = H2code::Config::Config.new
    app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
    app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
    app.voice_active?.should be_false
    app.@last_space_at.should be_nil
  end
end
