require "../spec_helper"

describe Hcode::Notify::TerminalChannel do
  describe ".format" do
    it "joins title and body with a colon" do
      Hcode::Notify::TerminalChannel.format("Turn complete", "3 steps").should eq("Turn complete: 3 steps")
    end

    it "returns title alone when body is empty" do
      Hcode::Notify::TerminalChannel.format("Done", "").should eq("Done")
    end

    it "sanitizes control characters" do
      Hcode::Notify::TerminalChannel.format("a\x01b\x1fc", "").should eq("a b c")
    end

    it "collapses whitespace runs" do
      Hcode::Notify::TerminalChannel.format("foo   bar", "  baz").should eq("foo bar: baz")
    end

    it "caps the message length" do
      msg = Hcode::Notify::TerminalChannel.format("x" * 300, "")
      msg.size.should eq(Hcode::Notify::MAX_MESSAGE_LENGTH)
    end
  end

  describe ".build_sequences" do
    it "emits OSC 9 on capable terminals" do
      seqs = Hcode::Notify::TerminalChannel.build_sequences("hello", supports_osc9: true, inside_tmux: false)
      seqs.should eq(["\e]9;hello\a"])
    end

    it "falls back to BEL when OSC 9 is unsupported" do
      seqs = Hcode::Notify::TerminalChannel.build_sequences("hello", supports_osc9: false, inside_tmux: false)
      seqs.should eq(["\a"])
    end

    it "wraps OSC 9 in tmux DCS passthrough" do
      seqs = Hcode::Notify::TerminalChannel.build_sequences("hi", supports_osc9: true, inside_tmux: true)
      seqs.size.should eq(1)
      seqs[0].should start_with("\ePtmux;")
      seqs[0].should end_with("\e\\")
      # ESC bytes inside the payload are doubled
      seqs[0].includes?("\e\e]9;hi\a").should be_true
    end

    it "BEL is unwrapped even inside tmux" do
      seqs = Hcode::Notify::TerminalChannel.build_sequences("hi", supports_osc9: false, inside_tmux: true)
      seqs.should eq(["\a"])
    end

    it "returns empty for an empty message" do
      Hcode::Notify::TerminalChannel.build_sequences("", true, false).should eq([] of String)
    end
  end

  describe ".supports_osc9?" do
    it "detects iTerm.app via TERM_PROGRAM" do
      env = {"TERM_PROGRAM" => "iTerm.app"} of String => String
      Hcode::Notify::TerminalChannel.supports_osc9?(env).should be_true
    end

    it "detects Kitty via TERM" do
      env = {"TERM" => "xterm-kitty"} of String => String
      Hcode::Notify::TerminalChannel.supports_osc9?(env).should be_true
    end

    it "returns false for unknown terminals" do
      env = {} of String => String
      Hcode::Notify::TerminalChannel.supports_osc9?(env).should be_false
    end
  end

  describe ".inside_tmux?" do
    it "detects tmux via TMUX env" do
      Hcode::Notify::TerminalChannel.inside_tmux?({"TMUX" => "/tmp/tmux-1000/default,123,0"} of String => String).should be_true
    end

    it "returns false without TMUX" do
      Hcode::Notify::TerminalChannel.inside_tmux?({} of String => String).should be_false
    end
  end

  describe "write path" do
    it "writes OSC 9 bytes to the output IO" do
      io = IO::Memory.new
      channel = Hcode::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      channel.notify("turn_done", "Done", "")
      io.to_s.should eq("\e]9;Done\a")
    end

    it "de-dupes by key so a repeated event does not spam" do
      io = IO::Memory.new
      channel = Hcode::Notify::TerminalChannel.new(io, "always", supports_osc9: true, inside_tmux: false)
      channel.notify("turn_done", "Done", "")
      channel.notify("turn_done", "Done again", "")
      io.to_s.should eq("\e]9;Done\a")
    end

    it "skips when unfocused condition is met and terminal is focused" do
      io = IO::Memory.new
      channel = Hcode::Notify::TerminalChannel.new(io, "unfocused", supports_osc9: true, inside_tmux: false)
      channel.focused = true
      channel.notify("turn_done", "Done", "")
      io.to_s.should be_empty
    end
  end
end
