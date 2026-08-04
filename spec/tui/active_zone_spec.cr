require "spec"

require "../../src/tui/terminal_port"
require "../../src/tui/terminal_mock"
require "../../src/tui/active_zone"

describe Hcode::TUI::ActiveZone do
  it "growing: draws exactly the zone lines and no blank padding" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set(["l0", "l1", "l2"] of String)
    mock = Hcode::TUI::TerminalMock.new

    zone.render(mock, available_rows: 24)

    mock.output.should eq(["l0", "l1", "l2"])
    zone.height_log.should eq([3])
    zone.height.should eq(3)
    zone.trailing_blanks.should eq(0)
  end

  it "shrinking: pads blank rows for the height difference (10 -> 8 = 2 blanks)" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set((0...10).map { |i| "x#{i}" })
    mock = Hcode::TUI::TerminalMock.new
    zone.render(mock, available_rows: 24) # prev frame: 10 visible
    zone.prev_height.should eq(10)
    zone.trailing_blanks.should eq(0)

    zone.set((0...8).map { |i| "y#{i}" })
    mock2 = Hcode::TUI::TerminalMock.new
    mock2.cursor_row.should eq(0) # fresh mock
    zone.render(mock2, available_rows: 24) # now 8 → pad 2

    # 8 content rows + 2 blank rows.
    mock2.output.should eq(["y0", "y1", "y2", "y3", "y4", "y5", "y6", "y7", "", ""])
    zone.height_log.should eq([10, 8])
    zone.trailing_blanks.should eq(2)
    zone.shift_available?.should be_true
  end

  it "clamps drawing to available_rows when the zone is taller than viewport" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set((0...15).map { |i| "z#{i}" })
    mock = Hcode::TUI::TerminalMock.new
    zone.render(mock, available_rows: 5)

    # First 5 rows drawn (A1 at top); tail z5..z14 clipped.
    mock.output.should eq(["z0", "z1", "z2", "z3", "z4"])
    zone.height_log.last.should eq(5)
  end

  it "blank padding is clamped to the viewport" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set((0...5).map { |i| "a#{i}" })
    mock = Hcode::TUI::TerminalMock.new
    zone.render(mock, available_rows: 5) # prev visible 5

    zone.set((0...2).map { |i| "b#{i}" })
    mock2 = Hcode::TUI::TerminalMock.new
    # available_rows smaller than prev_visible: padding limited to available(3) - visible(2) = 1 blank.
    zone.render(mock2, available_rows: 3)

    mock2.output.should eq(["b0", "b1", ""])
    zone.height_log.last.should eq(2)
    zone.trailing_blanks.should eq(1)
  end

  it "height_log is capped" do
    zone = Hcode::TUI::ActiveZone.new
    20.times do
      zone.set(["only"] of String)
      zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)
    end
    zone.height_log.size.should eq(Hcode::TUI::ActiveZone::HEIGHT_LOG_CAP)
  end

  it "reset clears state, height log, and trailing blanks" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set(["a", "b"] of String)
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)

    zone.reset
    zone.height.should eq(0)
    zone.height_log.should be_empty
    zone.prev_height.should eq(0)
    zone.trailing_blanks.should eq(0)
  end

  it "consume_blank decrements trailing_blanks" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set((0...4).map { |i| "a#{i}" })
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)

    zone.set(["a0"] of String)
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)
    zone.trailing_blanks.should eq(3)
    zone.shift_available?.should be_true

    zone.consume_blank
    zone.trailing_blanks.should eq(2)
    zone.consume_blank
    zone.trailing_blanks.should eq(1)
    zone.consume_blank
    zone.trailing_blanks.should eq(0)
    zone.shift_available?.should be_false

    # Does not go below 0
    zone.consume_blank
    zone.trailing_blanks.should eq(0)
  end

  it "growth consumes trailing blanks" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set((0...5).map { |i| "a#{i}" })
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)

    # Shrink to 2 → 3 blanks
    zone.set(["a0", "a1"] of String)
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)
    zone.trailing_blanks.should eq(3)

    # Grow to 4 → consumes 2 blanks
    zone.set((0...4).map { |i| "b#{i}" })
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)
    zone.trailing_blanks.should eq(1)
  end

  it "visible == prev_visible keeps trailing_blanks unchanged" do
    zone = Hcode::TUI::ActiveZone.new
    zone.set(["a0", "a1", "a2"] of String)
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)

    # Shrink to 1 → 2 blanks
    zone.set(["a0"] of String)
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)
    zone.trailing_blanks.should eq(2)

    # Consume 1 (simulating a log push shift)
    zone.consume_blank
    zone.trailing_blanks.should eq(1)

    # Render same size → trailing_blanks unchanged
    zone.set(["c0"] of String)
    zone.render(Hcode::TUI::TerminalMock.new, available_rows: 24)
    zone.trailing_blanks.should eq(1)
  end
end
