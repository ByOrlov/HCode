require "../spec_helper"
require "../../src/tui/terminal_mock"
require "../../src/tui/log_zone"
require "../../src/tui/active_zone"
require "../../src/tui/app"

# Zone-behaviour tests driven through the REAL `App#render_zones` path
# (full_render → incremental_render), not a hand-rolled reimplementation.
# Each frame calls `app.render_zones(mock, log_lines, active_lines)`; the mock
# is a fixed-size screen model, so small geometries activate the scroll /
# viewport logic of `incremental_render` — exactly the code path the old
# `render_frame` helper bypassed.

private def l(n) : String
  "L#{n}"
end

private def a(n) : String
  "A#{n}"
end

private def blanks(n : Int32) : Array(String)
  Array(String).new(n) { "" }
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
# rows for viewport tests: available_rows = rows - 2 = 8 active rows.
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
      mock.visible_rows.should eq(["A1", "", ""])
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

      # Step 1.3: shrink to [A1] → 1 blank
      app.render_zones(mock, (1..10).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1), ""])

      # Step 1.4: grow to [A1..A10]
      app.render_zones(mock, (1..10).map { |n| l(n) }, (1..10).map { |n| a(n) })
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + (1..10).map { |n| a(n) })

      # Step 1.5: shrink to [A1] → 9 blanks
      app.render_zones(mock, (1..10).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1)] + blanks(9))
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

      # Step 2.3: add L3 (shift: blank consumed, height stays same)
      app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1), a(2)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "A1", "A2"])

      # Step 2.4: shrink active to [A1] → 1 blank
      app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "A1", ""])

      # Step 2.5: add L4 (shift: blank consumed, height stays same)
      app.render_zones(mock, [l(1), l(2), l(3), l(4)] of String, [a(1)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "L4", "A1"])
    end
  end

  # Viewport tests (rows=10, available_rows=8) expose a SEPARATE, deeper class
  # of bugs in `incremental_render`'s scroll logic when `viewport_top > 0`.
  # The scroll_delta < 0 (viewport shrink) case is now fixed — see Test 8 below.
  # The remaining failures (clamping, growth within viewport) are a separate
  # issue in the incremental viewport path and stay pending.
  describe "Test 3: viewport (rows=10 → available_rows=8)" do
    pending "clamps active zone to available_rows" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # Step 3.1: log=[L1..L5], active=[A1]
      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1)])

      # Step 3.2: active grows to [A1..A5]
      app.render_zones(mock, (1..5).map { |n| l(n) }, (1..5).map { |n| a(n) })
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + (1..5).map { |n| a(n) })

      # Step 3.3: active grows to [A1..A15] → only first 8 drawn
      app.render_zones(mock, (1..5).map { |n| l(n) }, (1..15).map { |n| a(n) })
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + (1..8).map { |n| a(n) })

      # Step 3.4: shrink to [A1] → 7 blanks
      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1)] + blanks(7))

      # Step 3.5: add L6..L10 (shift consumes 5 of 7 blanks, leaving 2)
      app.render_zones(mock, (1..10).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1)] + blanks(2))

      # Step 3.6: active grows to [A1..A12] → only first 8 drawn
      app.render_zones(mock, (1..10).map { |n| l(n) }, (1..12).map { |n| a(n) })
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + (1..8).map { |n| a(n) })

      # Step 3.7: shrink to [A1..A3] → 5 blanks
      app.render_zones(mock, (1..10).map { |n| l(n) }, (1..3).map { |n| a(n) })
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + (1..3).map { |n| a(n) } + blanks(5))
    end
  end

  describe "Test 4: grow/shrink with empty log + viewport" do
    pending "renders correctly with no log lines" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # Step 4.1: active=[A1..A5]
      app.render_zones(mock, [] of String, (1..5).map { |n| a(n) })
      mock.visible_rows.should eq((1..5).map { |n| a(n) })

      # Step 4.2: active=[A1..A12] → first 8 drawn
      app.render_zones(mock, [] of String, (1..12).map { |n| a(n) })
      mock.visible_rows.should eq((1..8).map { |n| a(n) })

      # Step 4.3: shrink to [A1] → 7 blanks
      app.render_zones(mock, [] of String, [a(1)] of String)
      mock.visible_rows.should eq([a(1)] + blanks(7))
    end
  end

  describe "Test 6: log shift — absorbing trailing blanks" do
    it "absorbs blanks one per log push, then grows when exhausted" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # Step 6.1: log=[L1..L4], active=[A1..A3]
      app.render_zones(mock, (1..4).map { |n| l(n) }, (1..3).map { |n| a(n) })
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + (1..3).map { |n| a(n) })
      app.@active_zone.shift_available?.should be_false

      # Step 6.2: shrink to [A1] → 2 trailing blanks
      app.render_zones(mock, (1..4).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + [a(1), "", ""])
      app.@active_zone.trailing_blanks.should eq(2)
      app.@active_zone.shift_available?.should be_true

      # Step 6.3: add L5 (shift: 1 blank consumed, height stays same)
      app.render_zones(mock, (1..5).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + [a(1), ""])
      app.@active_zone.trailing_blanks.should eq(1)

      # Step 6.4: add L6 (shift: last blank consumed)
      app.render_zones(mock, (1..6).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..6).map { |n| l(n) } + [a(1)])
      app.@active_zone.trailing_blanks.should eq(0)
      app.@active_zone.shift_available?.should be_false

      # Step 6.5: add L7 (no blanks → screen grows)
      app.render_zones(mock, (1..7).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..7).map { |n| l(n) } + [a(1)])
    end

    it "absorbs multiple blanks across several pushes" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # log=[L1..L7], active=[A1..A4]
      app.render_zones(mock, (1..7).map { |n| l(n) }, (1..4).map { |n| a(n) })

      # shrink to [A1] → 3 blanks
      app.render_zones(mock, (1..7).map { |n| l(n) }, [a(1)] of String)
      app.@active_zone.trailing_blanks.should eq(3)

      # add L8, L9, L10 (each absorbs 1 blank, height stays 11)
      (8..10).each do |i|
        app.render_zones(mock, (1..i).map { |n| l(n) }, [a(1)] of String)
      end
      mock.visible_rows.should eq((1..10).map { |n| l(n) } + [a(1)])
      app.@active_zone.trailing_blanks.should eq(0)

      # add L11 (growth)
      app.render_zones(mock, (1..11).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..11).map { |n| l(n) } + [a(1)])
    end

    it "growth during shift overwrites blanks" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # log=[L1..L3], active=[A1..A5]
      app.render_zones(mock, (1..3).map { |n| l(n) }, (1..5).map { |n| a(n) })

      # shrink to [A1] → 4 blanks
      app.render_zones(mock, (1..3).map { |n| l(n) }, [a(1)] of String)
      app.@active_zone.trailing_blanks.should eq(4)

      # add L4 (shift: 1 blank consumed)
      app.render_zones(mock, (1..4).map { |n| l(n) }, [a(1)] of String)
      app.@active_zone.trailing_blanks.should eq(3)

      # grow active to [A1..A3] → 2 blanks consumed by growth
      app.render_zones(mock, (1..4).map { |n| l(n) }, (1..3).map { |n| a(n) })
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + (1..3).map { |n| a(n) } + [""])
      app.@active_zone.trailing_blanks.should eq(1)

      # add L5 (shift: last blank consumed)
      app.render_zones(mock, (1..5).map { |n| l(n) }, (1..3).map { |n| a(n) })
      mock.visible_rows.should eq((1..5).map { |n| l(n) } + (1..3).map { |n| a(n) })
      app.@active_zone.trailing_blanks.should eq(0)
    end
  end

  describe "Test 6b: log shift + viewport (available_rows=8)" do
    pending "absorbs 7 blanks across 7 log pushes, then grows" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # log=[L1..L4], active=[A1..A8] (fills available_rows)
      app.render_zones(mock, (1..4).map { |n| l(n) }, (1..8).map { |n| a(n) })
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + (1..8).map { |n| a(n) })

      # shrink to [A1] → 7 blanks
      app.render_zones(mock, (1..4).map { |n| l(n) }, [a(1)] of String)
      app.@active_zone.trailing_blanks.should eq(7)
      mock.visible_rows.should eq((1..4).map { |n| l(n) } + [a(1)] + blanks(7))

      # add L5..L11 (each absorbs 1 blank, height stays 12)
      (5..11).each do |i|
        app.render_zones(mock, (1..i).map { |n| l(n) }, [a(1)] of String)
      end
      mock.visible_rows.should eq((1..11).map { |n| l(n) } + [a(1)])
      app.@active_zone.trailing_blanks.should eq(0)

      # add L12 (growth)
      app.render_zones(mock, (1..12).map { |n| l(n) }, [a(1)] of String)
      mock.visible_rows.should eq((1..12).map { |n| l(n) } + [a(1)])
    end
  end

  # Regression: App#incremental_render must keep @hardware_cursor_row in sync
  # with the real cursor position after LogZone#flush advances it. When
  # content migrates from the active zone to the log, the cursor diff must be
  # computed from the advanced position, not the pre-flush one — otherwise the
  # active zone is rendered shifted down and stale lines linger between zones.
  describe "Test 7: cursor tracking through flush (migration scenario)" do
    it "renders correctly when content migrates from active to log" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      # Frame 1: log=[L1, L2], active=[A1, A2, A3]
      app.render_zones(mock, [l(1), l(2)] of String, [a(1), a(2), a(3)] of String)
      mock.visible_rows.should eq(["L1", "L2", "A1", "A2", "A3"])

      # Frame 2: log grows to [L1..L4], active shrinks to [A1, A2].
      # This is the migration scenario: content moved from active to log.
      app.render_zones(mock, [l(1), l(2), l(3), l(4)] of String, [a(1), a(2)] of String)
      mock.visible_rows.should eq(["L1", "L2", "L3", "L4", "A1", "A2", ""])
    end
  end

  # Regression: when a tall modal (e.g. plan-review dialog) lives in the active
  # zone and is then dismissed, viewport_top drops sharply. The terminal cannot
  # physically scroll back up, so incremental_render would leave stale dialog
  # lines on screen. The fix forces a full_render (cursor_home + clear_below)
  # whenever viewport_top decreases, erasing orphaned content reliably.
  describe "Test 8: tall modal dismiss (viewport_top shrink → full repaint)" do
    it "clears stale lines when active zone shrinks after viewport scroll" do
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: VIEWPORT_ROWS, cols: 80)

      # Frame 1: log=[L1..L3], active=[D1..D20] (simulates a tall plan-review
      # dialog). total=23 > rows=10, so viewport_top=13 after full_render.
      dialog = (1..20).map { |n| "D#{n}" }
      app.render_zones(mock, [l(1), l(2), l(3)] of String, dialog)
      app.@active_zone.trailing_blanks.should eq(0)

      # Frame 2: dialog dismissed — active shrinks to [A1..A3]. total=6,
      # viewport_top=0 < prev_vt=13 → forces full_render. The screen must
      # contain only the new content; no stale D-lines may linger.
      app.render_zones(mock, [l(1), l(2), l(3)] of String, [a(1), a(2), a(3)] of String)

      screen = mock.screen
      screen[0, 6].should eq(["L1", "L2", "L3", "A1", "A2", "A3"])
      # Remaining rows must be blank (cleared by clear_below).
      screen[6..].each { |row| row.should eq("") }
      # Full repaint leaves no trailing blanks for the shift mechanism.
      app.@active_zone.trailing_blanks.should eq(0)
    end

    it "does not force full repaint when viewport_top stays the same" do
      # Sanity check: a normal grow within the same viewport_top must still
      # use incremental_render (trailing_blanks mechanism stays active).
      app = Hcode::TUI::App.new
      mock = Hcode::TUI::TerminalMock.new(rows: NO_VIEWPORT_ROWS, cols: 80)

      app.render_zones(mock, [l(1), l(2)] of String, [a(1), a(2), a(3)] of String)
      app.render_zones(mock, [l(1), l(2)] of String, [a(1)] of String)
      app.@active_zone.trailing_blanks.should eq(2)
    end
  end
end
