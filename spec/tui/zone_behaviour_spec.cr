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

  # Viewport shrink (scroll_delta < 0): the active zone is anchored at the
  # bottom of the content, so when content shrank (modal dismissed, spinner
  # gone at turn end, log compacted) the zone moves DOWN on screen and the rows
  # it vacated at the top go stale — the terminal cannot scroll back up on its
  # own. incremental_render must clear those freed rows.
  describe "Test 8: content shrink (viewport_top shrink → stale rows cleared)" do
    it "clears stale lines when the active zone shrinks after viewport scroll" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # Frame 1: log=[L1..L3], active=[D1..D20] (tall dialog). total=23 > rows,
      # so the screen shows the bottom of the dialog.
      dialog = (1..20).map { |n| "D#{n}" }
      drain(app, mock, [l(1), l(2), l(3)] of String, dialog)

      # Frame 2: dialog dismissed — active shrinks to [A1..A3]. total=6,
      # viewport_top=0 < prev_vt → stale rows above the active zone must be
      # cleared, no D-lines survive on screen. (L1..L3 scrolled into scrollback
      # while the tall dialog was shown and are not re-emitted; restoring them
      # would need a full repaint, which is out of scope for the incremental
      # path.)
      app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1), a(2), a(3)] of String)

      screen = mock.screen
      screen.should_not contain("D1")
      (1..20).each { |n| screen.should_not contain("D#{n}") }
      screen[3, 3].should eq(["A1", "A2", "A3"])
      screen[6..].each { |row| row.should eq("") }
    end

    it "clears the stale row when the spinner line disappears at turn end" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # log=[L1..L9], active=[S (spinner), A1] — total=11, viewport_top=1.
      app.render_zones(mock, (1..9).map { |n| l(n) }, ["S", a(1)] of String)

      # Spinner dismissed: active shrinks to [A1]. total=10, viewport_top=0,
      # scroll_delta=-1 → the row the spinner vacated must be cleared, leaving
      # no stale "S" on screen.
      app.render_zones(mock, (1..9).map { |n| l(n) }, [a(1)] of String)

      screen = mock.screen
      screen.should_not contain("S")
    end
  end

  # When the active zone fills the screen to the bottom row and then shrinks,
  # cursor_down(1) from the last row is clamped. Previously clear_below would
  # then wipe the last active line instead of clearing rows below the zone.
  # The fix: only clear_below when content doesn't fill the screen.
  describe "Test 9: shrink at screen bottom — last active line preserved" do
    it "does not wipe the last active line when zone shrinks at bottom" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: 13, cols: 80)

      # total=13 == rows, active fills to bottom
      app.render_zones(mock, (1..5).map { |n| l(n) }, (1..8).map { |n| a(n) })
      mock.screen[12].should eq("A8")

      # active shrinks 8→5, log grows +3, total stays 13
      app.render_zones(mock, (1..8).map { |n| l(n) }, (1..5).map { |n| a(n) })

      mock.screen.should eq(
        (1..8).map { |n| l(n) } + (1..5).map { |n| a(n) }
      )
    end

    it "does not wipe the last active line on the first frame at bottom" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: 5, cols: 80)

      app.render_zones(mock, [] of String, (1..5).map { |n| a(n) })
      mock.screen.should eq((1..5).map { |n| a(n) })
    end
  end

  # When scroll_delta < 0 (viewport moved up because content shrank), every
  # visible row now maps to different content. The terminal cannot scroll down
  # on its own, so incremental_render must do a full repaint of the visible area.
  describe "Test 10: viewport shrink → full repaint" do
    it "rewrites all visible lines when viewport_top decreases" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: 12, cols: 80)

      # Frame 1: log=[L1..L7], active=[A1..A5] → total=12, VT=0
      app.render_zones(mock, (1..7).map { |n| l(n) }, (1..5).map { |n| a(n) })

      # Frame 2: active grows to 8 → total=15, VT=3
      app.render_zones(mock, (1..7).map { |n| l(n) }, (1..8).map { |n| a(n) })

      # Frame 3: active shrinks to 5 → total=12, VT=0, scroll_delta=-3
      app.render_zones(mock, (1..7).map { |n| l(n) }, (1..5).map { |n| a(n) })

      screen = mock.screen
      # No stale active-zone lines from the taller frame
      (1..8).each { |n| screen.should_not contain("A#{n}") unless n <= 5 }
      # All visible lines rewritten correctly — no blank rows.
      screen[0, 7].should eq((1..7).map { |n| l(n) })
      screen[7, 5].should eq((1..5).map { |n| a(n) })
    end

    it "rewrites all visible lines on viewport shrink (partial)" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: 12, cols: 80)

      # Frame 1: log=[L1..L9], active=[A1..A5] → total=14, VT=2
      drain(app, mock, (1..9).map { |n| l(n) }, (1..5).map { |n| a(n) })

      # Frame 2: active shrinks to 3 → total=12, VT=0, scroll_delta=-2
      app.render_zones(mock, (1..9).map { |n| l(n) }, (1..3).map { |n| a(n) })

      screen = mock.screen
      # All visible lines rewritten — no blank rows.
      screen[0, 9].should eq((1..9).map { |n| l(n) })
      screen[9, 3].should eq((1..3).map { |n| a(n) })
    end
  end
end
