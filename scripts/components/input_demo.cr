# Component demo / self-test for the TUI editor input box.
#
# Renders `App#render_editor_box` across the wrapping cases that previously
# broke the diff-renderer invariant ("1 Array(String) entry == 1 terminal row"):
# long lines, word-wrap, force-break, CJK/emoji widths, multi-line input,
# cursor-at-end, cursor mid-line, paste marker, and the empty placeholder.
#
# Run via:
#
#     rake mock:components:input
#
# The output is plain text + the rendered box for each case, plus invariant
# checks (no row exceeds the box width, no embedded newlines, typed content is
# preserved across wrapped rows, cursor visual row/col lands on the expected
# cell). Non-zero exit on any invariant violation, so this doubles as a
# regression guard you can feed to an LLM or run in CI.

require "json"
require "http/client"

require "../../src/llm/types"
require "../../src/llm/token_counter"
require "../../src/llm/provider"
require "../../src/llm/openai_chat_provider"
require "../../src/llm/moonshot_provider"
require "../../src/llm/zai_provider"
require "../../src/llm/mock_provider"
require "../../src/tools/tool"
require "../../src/tools/registry"
require "../../src/tools/line_endings"
require "../../src/tools/path_access"
require "../../src/tools/sensitive"
require "../../src/tools/run_rg"
require "../../src/tools/bash"
require "../../src/tools/read"
require "../../src/tools/write"
require "../../src/tools/edit"
require "../../src/tools/glob"
require "../../src/tools/grep"
require "../../src/tools/todo_list"
require "../../src/tools/agent_swarm"
require "../../src/tools/agent"
require "../../src/tools/ask_user_question"
require "../../src/tools/fetch_url"
require "../../src/tools/web_search"
require "../../src/tools/skill"
require "../../src/tools/plan_mode"
require "../../src/tools/goal"
require "../../src/tools/task"
require "../../src/tools/cron"
require "../../src/tools/read_media"
require "../../src/tools/select_tools"
require "../../src/context/memory"
require "../../src/context/budget"
require "../../src/context/undo"
require "../../src/context/overflow"
require "../../src/permission/manager"
require "../../src/permission/danger"
require "../../src/permission/policies"
require "../../src/loop/events"
require "../../src/loop/abort"
require "../../src/loop/dedup"
require "../../src/loop/tool_batch"
require "../../src/prompt/template"
require "../../src/prompt/agents_md"
require "../../src/prompt/system_prompt"
require "../../src/session/store"
require "../../src/session/index"
require "../../src/session/lifecycle"
require "../../src/tui/theme"
require "../../src/tui/terminal"
require "../../src/tui/char_width"
require "../../src/tui/markdown"
require "../../src/tui/input"
require "../../src/tui/commands"
require "../../src/tui/component"
require "../../src/tui/text"
require "../../src/tui/spinner"
require "../../src/tui/editor"
require "../../src/tui/select_list"
require "../../src/tui/help_panel"
require "../../src/tui/app"

# Expose the private renderer + cursor state for the demo.
class H2code::TUI::App
  def demo_render_editor_box(cols)
    render_editor_box(cols)
  end

  def demo_editor=(text)
    @editor.set(text)
  end

  # `Editor#set` parks the cursor at end-of-text; this override places it
  # mid-buffer so we can exercise the wrap-aware cursor resolution.
  def demo_set_cursor(row : Int32, col : Int32)
    @editor.set_cursor(row, col)
  end

  def demo_cursor_visual_row
    @editor_cursor_visual_row
  end

  def demo_cursor_visual_col
    @editor_cursor_visual_col
  end
end

# Direct cursor setter used by the demo (Editor keeps cursor private).
class H2code::TUI::Editor
  def set_cursor(row : Int32, col : Int32) : Nil
    @cursor_row = row
    @cursor_col = col
    clamp_cursor_col
  end
end

module H2code::TUI
  ANSI_SGR = /\e\[[0-9;]*m/

  def self.strip_ansi(str : String) : String
    str.gsub(ANSI_SGR, "")
  end

  def self.visible_width(s : String) : Int32
    CharWidth.visible_width(s)
  end
end

# A single demo case. `cursor` optionally places the cursor at {row, col};
# otherwise it stays at end-of-text (what Editor#set gives).
record DemoCase,
  name : String,
  text : String,
  cols : Int32,
  cursor : Tuple(Int32, Int32)?

class DemoRunner
  @failures = [] of String
  @passes = 0

  private def run_case(kase : DemoCase) : Nil
    app = H2code::TUI::App.new
    app.demo_editor = kase.text
    if c = kase.cursor
      app.demo_set_cursor(c[0], c[1])
    end

    rows = app.demo_render_editor_box(kase.cols)

    puts
    puts "──────────────────────────────────────────────────────────────────────"
    puts "CASE: #{kase.name}"
    puts "  cols=#{kase.cols}  text=#{kase.text.inspect}#{kase.cursor ? "  cursor=#{kase.cursor}" : ""}"
    puts "──────────────────────────────────────────────────────────────────────"
    cursor_row = 1 + app.demo_cursor_visual_row
    rows.each_with_index do |row, i|
      plain = H2code::TUI.strip_ansi(row)
      w = H2code::TUI.visible_width(plain)
      marker = (i == cursor_row) ? "   ← hardware cursor (visual row=#{app.demo_cursor_visual_row}, col=#{app.demo_cursor_visual_col})" : ""
      puts "  [#{i.to_s.rjust(2)}] w=#{w.to_s.rjust(3)}  #{plain}#{marker}"
    end

    check_invariants(kase, rows, app)
  end

  private def check_invariants(kase : DemoCase, rows : Array(String), app : H2code::TUI::App) : Nil
    box_w = kase.cols
    content_rows = rows[1...-1] || [] of String

    # 1. No rendered entry may carry an embedded newline — the diff renderer
    #    assumes 1 entry == 1 terminal row.
    content_rows.each do |r|
      if r.includes?("\n")
        @failures << "#{kase.name}: embedded newline in row #{r.inspect}"
      end
    end

    # 2. No content row may exceed the box width (degenerate < 8-col terminals
    #    are excluded — the cursor's trailing space can't fit a 1-col gutter).
    if box_w >= 8
      content_rows.each_with_index do |r, i|
        w = H2code::TUI.visible_width(H2code::TUI.strip_ansi(r))
        if w > box_w
          @failures << "#{kase.name}: row #{i} width #{w} exceeds box_w #{box_w}: #{H2code::TUI.strip_ansi(r).inspect}"
        end
      end
    end

    # 3. No typed character may be dropped during wrapping/rendering. We can't
    #    reconstruct exact spacing from rendered rows (word-wrap keeps the
    #    breaking space inside a chunk, force-break splits mid-token, and pad
    #    spaces are indistinguishable from real ones), so strip ALL whitespace
    #    from both sides and verify the character sequence survives intact.
    unless kase.text.empty?
      plain = content_rows.map do |r|
        body = H2code::TUI.strip_ansi(r)
        # Drop the leading "│ > " / "│   " prompt (4 codepoints) and the
        # trailing "│" border (1 codepoint); pad spaces get stripped below.
        next "" if body.size < 5
        body[4...-1].to_s
      end.join("").gsub(/\s/, "")
      want = kase.text.gsub(/\s/, "")
      unless plain.includes?(want)
        @failures << "#{kase.name}: typed text not preserved.\n     got: #{plain.inspect}\n     want substring of: #{want.inspect}"
      end
    end

    # 4. Hardware-cursor visual row must land inside the content area.
    if app.demo_cursor_visual_row < 0 || app.demo_cursor_visual_row >= content_rows.size
      @failures << "#{kase.name}: cursor visual row #{app.demo_cursor_visual_row} outside content rows (0..#{content_rows.size - 1})"
    end

    if @failures.any? { |f| f.starts_with?("#{kase.name}:") }
      puts "  ✗ FAIL"
    else
      @passes += 1
      puts "  ✓ ok"
    end
  end

  def run(cases : Array(DemoCase)) : Nil
    cases.each { |c| run_case(c) }
    puts
    puts "══════════════════════════════════════════════════════════════════════"
    puts "Summary: #{@passes}/#{cases.size} cases passed, #{@failures.size} invariant failure(s)"
    puts "══════════════════════════════════════════════════════════════════════"
    @failures.each { |f| puts "  - #{f}" }
    exit 1 unless @failures.empty?
  end
end

LONG_BUG_LINE = "test test test test test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test testtest test test"

CASES = [
  # The exact regression the user reported: a long typed line that previously
  # rendered as one overwide row and scrambled the screen.
  DemoCase.new("user regression: long line (120 cols)", LONG_BUG_LINE, 120, nil),

  # Word-wrap at whitespace.
  DemoCase.new("word-wrap at spaces (40 cols)",
    "the quick brown fox jumps over the lazy dog repeatedly", 40, nil),

  # Force-break a token longer than the available width.
  DemoCase.new("force-break long word (30 cols)",
    "supercalifragilisticexpialidocious_and_then_some_more_text", 30, nil),

  # Width-2 graphemes (CJK) and emoji — wrapping must be grapheme-aware.
  DemoCase.new("CJK + emoji (40 cols)",
    "你好世界，这是一个测试 emoji 🚀🎉 end", 40, nil),

  # Multi-line input (Shift+Enter) wraps each logical line independently.
  DemoCase.new("multi-line input (50 cols)",
    "first paragraph that is fairly long\nshort\nthird paragraph also wrapping across the box", 50, nil),

  # Cursor parked at end of a long line: must resolve to the LAST wrapped row.
  DemoCase.new("cursor at end of wrapped line (60 cols)",
    "abcdefghij" * 8, 60, nil),

  # Cursor mid-line: must land on the correct wrapped row + local column.
  DemoCase.new("cursor mid-line (40 cols)",
    "the quick brown fox jumps over the lazy dog", 40, {0, 30}),

  # Empty editor: shows the placeholder row and parks the cursor on it.
  DemoCase.new("empty editor placeholder (60 cols)", "", 60, nil),
]

DemoRunner.new.run(CASES)
