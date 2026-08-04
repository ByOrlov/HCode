require "spec"

require "../../src/tui/terminal_port"
require "../../src/tui/terminal_mock"
require "../../src/tui/log_zone"

describe Hcode::TUI::LogZone do
  it "emits only lines beyond the cursor and advances it" do
    zone = Hcode::TUI::LogZone.new
    mock = Hcode::TUI::TerminalMock.new

    emitted = zone.flush(mock, ["a", "b", "c"] of String)
    emitted.should eq(3)
    mock.output.should eq(["a", "b", "c"])
    zone.flushed.should eq(3)

    mock2 = Hcode::TUI::TerminalMock.new
    emitted = zone.flush(mock2, ["a", "b", "c"] of String)
    emitted.should eq(0)
    mock2.output.should be_empty
  end

  it "emits only the new lines on a subsequent flush" do
    zone = Hcode::TUI::LogZone.new
    mock = Hcode::TUI::TerminalMock.new

    zone.flush(mock, ["a"] of String)
    zone.flushed.should eq(1)

    emitted = zone.flush(mock, ["a", "b", "c"] of String)
    emitted.should eq(2)
    # First flush wrote "a" at row 0. Second flush: cursor at row 0,
    # cursor_down → row 1, write "b"; cursor_down → row 2, write "c".
    mock.output.should eq(["a", "b", "c"])
    zone.flushed.should eq(3)
  end

  it "flags shrank and emits nothing when history shrinks below the cursor" do
    zone = Hcode::TUI::LogZone.new
    mock = Hcode::TUI::TerminalMock.new
    zone.flush(mock, ["a", "b", "c", "d"] of String)
    zone.shrank?.should be_false

    mock2 = Hcode::TUI::TerminalMock.new
    emitted = zone.flush(mock2, ["a", "b"] of String)
    emitted.should eq(0)
    mock2.output.should be_empty
    zone.shrank?.should be_true
  end

  it "reset clears the cursor and the shrank flag" do
    zone = Hcode::TUI::LogZone.new
    mock = Hcode::TUI::TerminalMock.new
    zone.flush(mock, ["a", "b"] of String)
    zone.flush(Hcode::TUI::TerminalMock.new, [] of String) # shrink → shrank

    zone.reset
    zone.flushed.should eq(0)
    zone.shrank?.should be_false

    mock2 = Hcode::TUI::TerminalMock.new
    zone.flush(mock2, ["a", "b"] of String)
    mock2.output.should eq(["a", "b"])
  end

  it "mark_flushed aligns the cursor without emitting" do
    zone = Hcode::TUI::LogZone.new
    mock = Hcode::TUI::TerminalMock.new
    zone.flush(mock, ["a", "b", "c", "d"] of String)
    zone.flush(Hcode::TUI::TerminalMock.new, [] of String)

    zone.mark_flushed(2)
    zone.shrank?.should be_false
    zone.flushed.should eq(2)

    mock2 = Hcode::TUI::TerminalMock.new
    zone.flush(mock2, ["a", "b", "e"] of String)
    # Only "e" (index 2) is new; emitted at row 0.
    mock2.output.should eq(["e"])
  end
end
