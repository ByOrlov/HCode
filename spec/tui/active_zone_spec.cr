require "spec"

require "../../src/tui/terminal_port"
require "../../src/tui/terminal_mock"
require "../../src/tui/active_zone"

describe Hcode::TUI::ActiveZone do
  it "draws the active lines at the current cursor position" do
    zone = Hcode::TUI::ActiveZone.new
    mock = Hcode::TUI::TerminalMock.new(rows: 10, cols: 80)

    visible = zone.render(mock, ["l0", "l1", "l2"] of String, available_rows: 10, prev_visible: 0)

    visible.should eq(3)
    mock.output.should eq(["l0", "l1", "l2"])
  end

  it "tail-clips to available_rows when the zone is taller" do
    zone = Hcode::TUI::ActiveZone.new
    mock = Hcode::TUI::TerminalMock.new(rows: 10, cols: 80)

    lines = (0...15).map { |i| "z#{i}" }.to_a
    visible = zone.render(mock, lines, available_rows: 5, prev_visible: 0)

    visible.should eq(5)
    # Bottom 5 lines are drawn: z10..z14
    mock.output.should eq((10...15).map { |i| "z#{i}" }.to_a)
  end

  it "clears rows left over from a taller previous frame" do
    zone = Hcode::TUI::ActiveZone.new
    mock = Hcode::TUI::TerminalMock.new(rows: 10, cols: 80)

    zone.render(mock, ["a", "b", "c", "d", "e"] of String, available_rows: 10, prev_visible: 0)
    mock.output.should eq(["a", "b", "c", "d", "e"])

    mock2 = Hcode::TUI::TerminalMock.new(rows: 10, cols: 80)
    visible = zone.render(mock2, ["a", "b"] of String, available_rows: 10, prev_visible: 5)

    visible.should eq(2)
    mock2.output.should eq(["a", "b"])
  end

  it "does not clear rows when the zone grew or stayed the same" do
    zone = Hcode::TUI::ActiveZone.new
    mock = Hcode::TUI::TerminalMock.new(rows: 10, cols: 80)

    zone.render(mock, ["a", "b"] of String, available_rows: 10, prev_visible: 0)
    mock.output.should eq(["a", "b"])

    mock2 = Hcode::TUI::TerminalMock.new(rows: 10, cols: 80)
    visible = zone.render(mock2, ["a", "b", "c", "d"] of String, available_rows: 10, prev_visible: 2)

    visible.should eq(4)
    mock2.output.should eq(["a", "b", "c", "d"])
  end

  it "handles an empty active zone after a non-empty one" do
    zone = Hcode::TUI::ActiveZone.new
    mock = Hcode::TUI::TerminalMock.new(rows: 5, cols: 80)

    zone.render(mock, ["x"] of String, available_rows: 5, prev_visible: 0)
    mock.output.should eq(["x"])

    mock2 = Hcode::TUI::TerminalMock.new(rows: 5, cols: 80)
    visible = zone.render(mock2, [] of String, available_rows: 5, prev_visible: 1)

    visible.should eq(0)
    mock2.output.should be_empty
  end
end
