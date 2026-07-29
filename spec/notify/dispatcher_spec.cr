require "../spec_helper"

describe Hcode::Notify::Dispatcher do
  describe "#on_transition" do
    it "fans out to the terminal channel for turn_done" do
      io = IO::Memory.new
      terminal = Hcode::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      config = Hcode::Notify::Config.default
      dispatcher = Hcode::Notify::Dispatcher.new(config, terminal)

      dispatcher.on_transition(Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
        title: "Turn complete",
      ))

      io.to_s.should eq("\e]9;Turn complete\a")
    end

    it "fires the player for turn_done and input_required" do
      player = Hcode::Notify::Player.new(probe: false)
      config = Hcode::Notify::Config.default
      dispatcher = Hcode::Notify::Dispatcher.new(config, nil, player)

      # No crash — play_for is a no-op without a resolved player / missing files.
      dispatcher.on_transition(Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
      ))
      dispatcher.on_transition(Hcode::Notify::Transition.new(
        event: "input_required",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::InputRequired,
      ))
    end

    it "does nothing when globally disabled" do
      io = IO::Memory.new
      terminal = Hcode::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      config = Hcode::Notify::Config.default
      config.enabled = false
      dispatcher = Hcode::Notify::Dispatcher.new(config, terminal)

      dispatcher.on_transition(Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
        title: "Done",
      ))

      io.to_s.should be_empty
    end

    it "does not notify terminal on turn_started (intentionally silent)" do
      io = IO::Memory.new
      terminal = Hcode::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      config = Hcode::Notify::Config.default
      dispatcher = Hcode::Notify::Dispatcher.new(config, terminal)

      dispatcher.on_transition(Hcode::Notify::Transition.new(
        event: "turn_started",
        prev_status: Hcode::Notify::AgentStatus::Idle,
        next_status: Hcode::Notify::AgentStatus::Working,
        title: "Started",
      ))

      io.to_s.should be_empty
    end
  end

  describe ".from_config" do
    it "constructs a terminal channel when enabled" do
      config = Hcode::Notify::Config.default
      config.enabled = true
      config.terminal_enabled = true
      dispatcher = Hcode::Notify::Dispatcher.from_config(config)
      dispatcher.@terminal.should_not be_nil
    end

    it "skips all channels when globally disabled" do
      config = Hcode::Notify::Config.default
      config.enabled = false
      dispatcher = Hcode::Notify::Dispatcher.from_config(config)
      dispatcher.@terminal.should be_nil
      dispatcher.@player.should be_nil
      dispatcher.@webhook.should be_nil
    end

    it "skips webhook when URL is empty" do
      config = Hcode::Notify::Config.default
      config.webhook_enabled = true
      config.webhook_url = ""
      dispatcher = Hcode::Notify::Dispatcher.from_config(config)
      dispatcher.@webhook.should be_nil
    end
  end
end
