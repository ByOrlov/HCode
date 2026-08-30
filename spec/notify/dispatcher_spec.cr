require "../spec_helper"

describe H2code::Notify::Dispatcher do
  describe "#on_transition" do
    it "fans out to the terminal channel for turn_done" do
      io = IO::Memory.new
      terminal = H2code::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      config = H2code::Notify::Config.default
      dispatcher = H2code::Notify::Dispatcher.new(config, terminal)

      dispatcher.on_transition(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
        title: "Turn complete",
      ))

      io.to_s.should eq("\e]9;Turn complete\a")
    end

    it "fires the player for turn_done and input_required" do
      player = H2code::Notify::Player.new(enabled: false)
      config = H2code::Notify::Config.default
      dispatcher = H2code::Notify::Dispatcher.new(config, nil, player)

      # No crash — play_for is a no-op without a resolved player / missing files.
      dispatcher.on_transition(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
      ))
      dispatcher.on_transition(H2code::Notify::Transition.new(
        event: "input_required",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::InputRequired,
      ))
    end

    it "does nothing when globally disabled" do
      io = IO::Memory.new
      terminal = H2code::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      config = H2code::Notify::Config.default
      config.enabled = false
      dispatcher = H2code::Notify::Dispatcher.new(config, terminal)

      dispatcher.on_transition(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
        title: "Done",
      ))

      io.to_s.should be_empty
    end

    it "does not notify terminal on turn_started (intentionally silent)" do
      io = IO::Memory.new
      terminal = H2code::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      config = H2code::Notify::Config.default
      dispatcher = H2code::Notify::Dispatcher.new(config, terminal)

      dispatcher.on_transition(H2code::Notify::Transition.new(
        event: "turn_started",
        prev_status: H2code::Notify::AgentStatus::Idle,
        next_status: H2code::Notify::AgentStatus::Working,
        title: "Started",
      ))

      io.to_s.should be_empty
    end
  end

  describe ".from_config" do
    it "constructs a terminal channel when enabled" do
      config = H2code::Notify::Config.default
      config.enabled = true
      config.terminal_enabled = true
      dispatcher = H2code::Notify::Dispatcher.from_config(config)
      dispatcher.@terminal.should_not be_nil
    end

    it "skips all channels when globally disabled" do
      config = H2code::Notify::Config.default
      config.enabled = false
      dispatcher = H2code::Notify::Dispatcher.from_config(config)
      dispatcher.@terminal.should be_nil
      dispatcher.@player.should be_nil
      dispatcher.@webhook.should be_nil
    end

    it "skips webhook when URL is empty" do
      config = H2code::Notify::Config.default
      config.webhook_enabled = true
      config.webhook_url = ""
      dispatcher = H2code::Notify::Dispatcher.from_config(config)
      dispatcher.@webhook.should be_nil
    end
  end
end
