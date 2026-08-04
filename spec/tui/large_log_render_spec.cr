require "../spec_helper"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"

# Chunked log rendering: when a large block of text is pushed into the log zone
# at once (a tool that dumps hundreds of lines, or a streaming plan that
# migrates wholesale from the active zone), the LogZone must NOT try to flush it
# all in a single frame — that breaks the incremental scroll math (viewport
# jumps past the emission cursor, stale content lingers, blank rows appear).
#
# Instead the LogZone throttles emission to at most one viewport per frame,
# draining the rest across consecutive renders. This keeps the terminal buffer
# (scrollback + visible screen) continuous and correct at every step: no
# duplicates, no lost lines, no spurious blanks, no stale active-zone frame.

private def l(n) : String
  "L#{n}"
end

private def a(n) : String
  "A#{n}"
end

private def s(n) : String
  "S#{n}"
end

# rows=10, active=1 → chunk = rows - active = 9 new log lines per frame.
LR_ROWS = 10
CHUNK = 9

describe "Chunked log rendering (overflow)" do
  it "splits a large log block across frames of ≤ chunk" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: LR_ROWS, cols: 80)

    # Frame 1: small log baseline (flushed=2).
    app.render_zones(mock, [l(1), l(2)] of String, [a(1)] of String)
    mock.visible_rows.should eq(["L1", "L2", "A1"])

    full = (1..27).map { |n| l(n) }

    # Frame 2: push 25 new lines at once. reveal = min(27, 2+9) = 11.
    app.render_zones(mock, full, [a(1)] of String)
    app.@log_zone.pending?.should be_true
    mock.visible_rows.should eq((1..11).map { |n| l(n) } + [a(1)])

    # Frame 3: reveal = min(27, 11+9) = 20.
    app.render_zones(mock, full, [a(1)] of String)
    mock.visible_rows.should eq((1..20).map { |n| l(n) } + [a(1)])

    # Frame 4: final chunk drains the queue. reveal = 27.
    app.render_zones(mock, full, [a(1)] of String)
    app.@log_zone.pending?.should be_false
    mock.visible_rows.should eq(full + [a(1)])
  end

  it "buffer is duplicate-free and blank-free after draining a big block" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: LR_ROWS, cols: 80)
    full = (1..25).map { |n| l(n) }

    10.times do
      app.render_zones(mock, full, [a(1)] of String)
      break unless app.@log_zone.pending?
    end

    app.@log_zone.pending?.should be_false
    buf = mock.visible_rows
    buf.should eq(full + [a(1)])

    # No duplicates.
    dups = buf.tally.select { |_, c| c > 1 }
    dups.should be_empty
    # No blanks.
    buf.each_with_index { |row, i| row.should_not eq(""), "row #{i} is blank" }
  end

  it "log exactly fits one chunk (no split, no pending)" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: LR_ROWS, cols: 80)

    app.render_zones(mock, [] of String, [a(1)] of String)
    app.render_zones(mock, (1..CHUNK).map { |n| l(n) }, [a(1)] of String)
    app.@log_zone.pending?.should be_false
    mock.visible_rows.should eq((1..CHUNK).map { |n| l(n) } + [a(1)])
  end

  it "buffer stays continuous with small pushes after a big block" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: LR_ROWS, cols: 80)
    full = (1..25).map { |n| l(n) }

    10.times do
      app.render_zones(mock, full, [a(1)] of String)
      break unless app.@log_zone.pending?
    end
    mock.visible_rows.should eq(full + [a(1)])

    # Small increments after the block.
    app.render_zones(mock, (1..26).map { |n| l(n) }, [a(1)] of String)
    app.render_zones(mock, (1..27).map { |n| l(n) }, [a(1)] of String)
    app.@log_zone.pending?.should be_false
    mock.visible_rows.should eq((1..27).map { |n| l(n) } + [a(1)])
  end

  # Continuous streaming: many frames each pushing a few new log lines, like a
  # tool emitting output progressively. The buffer must stay correct throughout.
  it "progressive streaming keeps buffer continuous at every step" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: LR_ROWS, cols: 80)
    app.render_zones(mock, [] of String, [a(1)] of String)

    (1..40).each do |n|
      app.render_zones(mock, (1..n).map { |i| l(i) }, [a(1)] of String)
      # Drain any pending chunks from this push before the next.
      while app.@log_zone.pending?
        app.render_zones(mock, (1..n).map { |i| l(i) }, [a(1)] of String)
      end
      buf = mock.visible_rows
      buf.should eq((1..n).map { |i| l(i) } + [a(1)]), "after L#{n}"
    end
  end
end
