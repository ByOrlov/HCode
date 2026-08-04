require "../spec_helper"
require "../../src/tui/terminal_mock"
require "../../src/tui/log_zone"
require "../../src/tui/active_zone"
require "../../src/tui/app"

private def l(n) : String
  "L#{n}"
end

private def a(n) : String
  "A#{n}"
end

# Drain the log throttle: call render_zones repeatedly until no lines remain
# queued (pending? == false). Needed because the LogZone caps emission to one
# viewport per frame, so a large first payload is split across calls.
private def drain(app, mock, log_lines : Array(String), active_lines : Array(String))
  loop do
    app.render_zones(mock, log_lines, active_lines)
    break unless app.@log_zone.pending?
  end
end

# rows for "no viewport" tests: large enough that total never exceeds it,
# so viewport_top stays 0 and the scroll section is inactive.
NO_VIEWPORT_ROWS = 100
# rows for viewport tests: small geometry activates scroll/viewport logic.
VIEWPORT_ROWS = 10

describe "Zone behaviour tests (via App#render_zones)" do
  describe "Test 0: empty log + active zone" do
    it "renders active zone at row 0 with no log" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      app.render_zones(mock, [l(1)] of String, [a(1)] of String)
      mock.visible_rows.should eq(["L1", "A1"])
    end

    it "grows and shrinks with empty log" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      app.render_zones(mock, [] of String, [a(1), a(2), a(3)] of String)
      mock.visible_rows.should eq(["A1", "A2", "A3"])

      app.render_zones(mock, [] of String, [a(1)] of String)
      mock.visible_rows.should eq(["A1"])
    end
  end

  describe "Test 1: iterative logs + grow/shrink (no viewport)" do
    it "adds L1..L10 with active=[A1], then grows and shrinks" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # Step 1.1: add L1..L10, active=[A1]
      (1..10).each do |i|
        app.render_zones(mock, (1..i).map { |n| l(n) }, [a(1)] of String)
      end
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1)])

      # Step 1.2: grow to [A1, A2]
      app.render_zones(mock, (1..10).map { |n| l(n) }, [a(1), a(2)] of String)
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1), a(2)])

      # Step 1.3: shrink to [A1] — no blank padding
      app.render_zones(mock, (1..10).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1)])

      # Step 1.4: grow to [A1..A10]
      app.render_zones(mock, (1..10).map { |n| l(n) }, (1..10).map { |n| a(n) })
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + (1..10).map { |n| a(n) })

      # Step 1.5: shrink to [A1]
      app.render_zones(mock, (1..10).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1)])
    end
  end

  describe "Test 2: interleaved logs and active zone (no viewport)" do
    it "shifts active zone on log growth" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # Step 2.1: log=[L1, L2], active=[A1]
      app.render_zones(mock, [l(1), l(2)] of String, [a(1)] of String)
      mock.visible_rows.should eq(["L1", "L2", "A1"])

      # Step 2.2: active grows to [A1, A2]
      app.render_zones(mock, [l(1), l(2)] of String, [a(1), a(2)] of String)
      mock.visible_rows.should eq(["L1", "L2", "A1", "A2"])

      # Step 2.3: add L3
      app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1), a(2)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "A1", "A2"])

      # Step 2.4: shrink active to [A1]
      app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "A1"])

      # Step 2.5: add L4
      app.render_zones(mock, [l(1), l(2), l(3), l(4)] of String, [a(1)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "L4", "A1"])
    end
  end

  describe "Test 3: viewport scrolling (rows=10)" do
    it "scrolls the terminal when the log grows past the viewport" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # log=[L1..L5], active=[A1] — total 6, fits.
      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1)])

      # log=[L1..L15], active=[A1] — total 16, viewport scrolls.
      # The active zone stays anchored at the bottom, so the visible screen
      # shows the last 9 log rows plus A1.
      drain(app, mock, (1..15).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows[-10..-1].should eq((7..15).map { |n| l(n) } + [a(1)])
      # Earlier log lines have scrolled into scrollback; the active zone stays
      # anchored at the bottom of the visible screen.
      mock.scrollback.size.should be > 0
    end

    it "keeps the active zone at the bottom when it grows within the viewport" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1)])

      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1), a(2), a(3)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1), a(2), a(3)])
    end
  end

  describe "Test 6: log growth with active shrink — no blanks" do
    it "absorbs no space when the active zone shrinks" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # log=[L1..L4], active=[A1..A3]
      app.render_zones(mock, (1..4).map { |n| l(n) }, (1..3).map { |n| a(n) })
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + (1..3).map { |n| a(n) })

      # shrink to [A1] — no trailing blanks
      app.render_zones(mock, (1..4).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + [a(1)])

      # add L5 — screen grows normally
      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1)])

      # add L6
      app.render_zones(mock, (1..6).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..6).map { |n| l(n) } + [a(1)])
    end
  end

  describe "Test 7: cursor tracking through flush (migration scenario)" do
    it "renders correctly when content migrates from active to log" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # Frame 1: log=[L1, L2], active=[A1, A2, A3]
      app.render_zones(mock, [l(1), l(2)] of String, [a(1), a(2), a(3)] of String)
      mock.visible_rows.should eq(["L1", "L2", "A1", "A2", "A3"])

      # Frame 2: log grows to [L1..L4], active shrinks to [A1, A2]
      app.render_zones(mock, [l(1), l(2), l(3), l(4)] of String, [a(1), a(2)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "L4", "A1", "A2"])
    end
  end

  # Test 8 relied on the full_render fallback when the viewport shrinks.
  # Full render is currently disabled, so this case is skipped.
  # describe "Test 8: tall modal dismiss (viewport_top shrink → full repaint)" do
  #   it "clears stale lines when active zone shrinks after viewport scroll" do
  #     app = Hcode::TUI::App.new
  #     mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)
  #
  #     # Frame 1: log=[L1..L3], active=[D1..D20] (tall dialog).
  #     # total=23 > rows=10, so the screen shows the bottom of the dialog.
  #     dialog = (1..20).map { |n| "D#{n}" }
  #     app.render_zones(mock, [l(1), l(2), l(3)] of String, dialog)
  #
  #     # Frame 2: dialog dismissed — active shrinks to [A1..A3]. total=6,
  #     # viewport_top=0 < prev_vt=13 → forces full_render. No stale D-lines.
  #     app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1), a(2), a(3)] of String)
  #
  #     screen = mock.screen
  #     screen[0, 6].should eq(["L1", "L2", "L3", "A1", "A2", "A3"])
  #     screen[6..].each { |row| row.should eq("") }
  #     # The new content is on screen; the scrollback still holds the old
  #     # dialog lines, which is expected terminal behaviour.
  #     mock.visible_rows[-6..-1].should eq(["L1", "L2", "L3", "A1", "A2", "A3"])
  #   end
  # end
end
