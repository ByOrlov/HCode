require "../spec_helper"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"

# Property-based invariant tests for the incremental renderer.
#
# Two invariants are checked after every frame:
#
# 1. **Screen oracle (grow-only)** — in sequences that only grow (streaming,
#    active zone expands), `mock.screen` must equal a dumb unconditional
#    recompute. Catches stale-pixel bugs (the `clear_below` / viewport-shrink
#    class from `notes/bug_history.md`).
#
# 2. **No-blank-rows (grow+shrink)** — in sequences that grow AND shrink
#    (dialog dismiss, thinking finalizes, spinner gone), the visible screen
#    must never have blank rows where content should be. The terminal cannot
#    scroll down on its own, so viewport shrink rewrites all visible lines
#    from scratch. Leaving blank rows (as the @max_viewport_top approach did)
#    is a user-visible bug — blank lines appear in the transcript output.

private def l(n) : String
  "L#{n}"
end

private def a(n) : String
  "A#{n}"
end

# Dumb oracle: what the visible screen (rows top→bottom) MUST contain.
private def expected_screen(log_lines : Array(String), active_lines : Array(String), rows : Int32) : Array(String)
  all = log_lines + active_lines
  total = all.size
  vt = {0, total - rows}.max
  Array.new(rows) do |r|
    ci = vt + r
    ci < total ? all[ci] : ""
  end
end

# Drain the throttle: render until no lines remain queued.
private def drain(app, mock, log_lines : Array(String), active_lines : Array(String))
  loop do
    app.render_zones(mock, log_lines, active_lines)
    break unless app.@log_zone.pending?
  end
end

describe "Incremental renderer invariants" do
  # ── Invariant 1: screen oracle across grow-only sequences ──
  it "screen matches the dumb oracle across grow-only sequences" do
    rows = 10
    500.times do
      app = H2code::TUI::App.new
      mock = H2code::TUI::TerminalMock.new(rows: rows, cols: 80)
      log = [] of String
      active = [a(1)] of String
      seed = Random.new.rand(1_i64..1_000_000_000_i64)
      rng = Random.new(seed)

      25.times do
        case rng.rand(2)
        when 0
          base = log.size
          rng.rand(1..5).times { |i| log << l(base + i + 1) }
        when 1
          base = active.size
          rng.rand(1..3).times { |i| active << a(base + i + 1) }
        end

        drain(app, mock, log, active)
        got = mock.screen
        exp = expected_screen(log, active, rows)
        unless got == exp
          fail("stale screen (seed #{seed})\n  log=#{log}\n  active=#{active}\n  screen=#{got}\n  expected=#{exp}")
        end
      end
    end
  end

  # ── Invariant 2: no blank rows where content should be (grow+shrink) ──
  # This is the regression test for the "blank line between steps 131 and 132"
  # bug. When the viewport grows (active zone expands) then shrinks (active
  # zone contracts), the full repaint must rewrite ALL visible lines — never
  # leaving blank rows for content that exists in the log.
  it "visible screen has no unexpected blank rows across grow+shrink sequences" do
    rows = 10
    500.times do
      app = H2code::TUI::App.new
      mock = H2code::TUI::TerminalMock.new(rows: rows, cols: 80)
      log = [] of String
      active = [a(1)] of String
      seed = Random.new.rand(1_i64..1_000_000_000_i64)
      rng = Random.new(seed)
      log_seq = 0
      act_seq = 1

      25.times do
        case rng.rand(4)
        when 0
          rng.rand(1..6).times do
            log_seq += 1
            log << "L#{log_seq}"
          end
        when 1
          rng.rand(1..4).times { log.pop? }
        when 2
          rng.rand(1..3).times do
            act_seq += 1
            active << "A#{act_seq}" if active.size < 4
          end
        when 3
          floor = Math.min(1, active.size)
          n = Math.min(rng.rand(1..3), active.size - floor)
          n.times { active.pop }
        end

        drain(app, mock, log, active)

        # After draining, the screen must match the oracle exactly — no blank
        # rows where content should be.
        got = mock.screen
        exp = expected_screen(log, active, rows)
        unless got == exp
          # Find the first blank row that should have content.
          blank_at = nil
          exp.each_with_index do |e, i|
            if !e.empty? && got[i]? == ""
              blank_at = i
              break
            end
          end
          msg = blank_at ? "blank row at screen[#{blank_at}] (seed #{seed})" : "screen mismatch (seed #{seed})"
          fail("#{msg}\n  log=#{log}\n  active=#{active}\n  screen=#{got}\n  expected=#{exp}")
        end
      end
    end
  end

  # ── Regression: viewport grow-then-shrink leaves no blank rows ──
  # This is the exact pattern from the mockfast demo: the plan block fills the
  # log, thinking preview grows the active zone (+2 rows → viewport scrolls),
  # then thinking finalizes (active zone shrinks → full repaint). The full
  # repaint must rewrite the rows that were temporarily scrolled, not leave
  # them blank.
  it "rewrites temporarily-scrolled rows on viewport grow-then-shrink" do
    rows = 10
    app = H2code::TUI::App.new
    mock = H2code::TUI::TerminalMock.new(rows: rows, cols: 80)

    # Phase 1: fill log to exactly fill the screen (total = rows).
    drain(app, mock, (1..9).map { |n| l(n) }, [a(1)] of String)
    # Screen: L1..L9, A1 (total=10, viewport_top=0)

    # Phase 2: active grows by 2 → total=12, viewport_top=2. L1,L2 scroll.
    app.render_zones(mock, (1..9).map { |n| l(n) }, [a(1), a(2), a(3)] of String)

    # Phase 3: active shrinks back → total=10, viewport_top=0.
    # Full repaint must rewrite ALL visible lines, including L1,L2 which
    # were temporarily scrolled off. No blank rows.
    app.render_zones(mock, (1..9).map { |n| l(n) }, [a(1)] of String)

    screen = mock.screen
    screen.should eq(expected_screen((1..9).map { |n| l(n) }, [a(1)] of String, rows))
    # Specifically: row 0 must show L1, not a blank.
    screen[0].should eq("L1")
    screen[1].should eq("L2")
  end

  # ── Regression: Bug 1 (clear_below wipes last line at screen bottom) ──
  it "preserves the last active line when zone shrinks at screen bottom" do
    rows = 13
    app = H2code::TUI::App.new
    mock = H2code::TUI::TerminalMock.new(rows: rows, cols: 80)

    app.render_zones(mock, (1..5).map { |n| l(n) }, (1..8).map { |n| a(n) })
    mock.screen[12].should eq("A8")

    app.render_zones(mock, (1..8).map { |n| l(n) }, (1..5).map { |n| a(n) })
    mock.screen.should eq(expected_screen((1..8).map { |n| l(n) }, (1..5).map { |n| a(n) }, rows))
    mock.screen[12].should eq("A5")
  end

  # ── Regression: Bug 2 (viewport shrink leaves stale active-zone rows) ──
  it "clears stale active-zone content on viewport shrink" do
    rows = 12
    app = H2code::TUI::App.new
    mock = H2code::TUI::TerminalMock.new(rows: rows, cols: 80)

    app.render_zones(mock, (1..7).map { |n| l(n) }, (1..5).map { |n| a(n) })
    app.render_zones(mock, (1..7).map { |n| l(n) }, (1..8).map { |n| a(n) })
    app.render_zones(mock, (1..7).map { |n| l(n) }, (1..5).map { |n| a(n) })

    mock.screen.should eq(expected_screen((1..7).map { |n| l(n) }, (1..5).map { |n| a(n) }, rows))
    (6..8).each { |n| mock.screen.join.should_not contain("A#{n}") }
  end
end
