require "../spec_helper"
require "../../src/tui/component"
require "../../src/tui/text"
require "../../src/tui/spinner"
require "../../src/tui/editor"
require "../../src/tui/markdown"
require "../../src/tui/select_list"
require "../../src/tui/diff"
require "../../src/tui/help_panel"
require "../../src/tui/app"

def app_strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

def app_render_lines(app : Hcode::TUI::App, width = 80) : Array(String)
  # App#build_rendered_lines is private; reach the same output through render_message.
  app.@messages.flat_map { |msg| app.render_message(msg, width) }
end

def help_strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

describe Hcode::TUI::App do
  it "renders a step summary when older thinking/tool blocks are merged" do
    app = Hcode::TUI::App.new
    app.keep_recent_steps = 2

    app.add_message("user", "hello")

    3.times do |i|
      app.on_event(Hcode::Loop::Event.thinking_delta("thinking #{i}"))
      app.on_event(Hcode::Loop::Event.text_delta("text #{i}"))
    end

    app.@messages.count { |m| m.role == "thinking" }.should eq(2)
    summary = app.@messages.find { |m| m.role == "step_summary" }
    summary.should_not be_nil
    summary.not_nil!.thinking_count.should eq(1)
    summary.not_nil!.tool_count.should eq(0)
  end

  it "keeps the most recent steps visible after merging" do
    app = Hcode::TUI::App.new
    app.keep_recent_steps = 2

    app.add_message("user", "hello")

    4.times do |i|
      app.on_event(Hcode::Loop::Event.thinking_delta("thought #{i}"))
      app.on_event(Hcode::Loop::Event.text_delta("text #{i}"))
    end

    visible_thinking = app.@messages.select { |m| m.role == "thinking" }.map(&.content)
    visible_thinking.size.should eq(2)
    visible_thinking.should eq(["thought 2", "thought 3"])

    summary = app.@messages.find { |m| m.role == "step_summary" }.not_nil!
    summary.thinking_count.should eq(2)
  end

  it "merges mixed thinking and tool blocks" do
    app = Hcode::TUI::App.new
    app.keep_recent_steps = 2

    app.add_message("user", "hello")

    app.on_event(Hcode::Loop::Event.thinking_delta("plan"))
    app.on_event(Hcode::Loop::Event.text_delta("t1"))

    app.on_event(Hcode::Loop::Event.tool_call_start("c1", "Glob", %({"pattern":"*.cr"})))
    app.on_event(Hcode::Loop::Event.tool_result("c1", "a.cr", false))

    app.on_event(Hcode::Loop::Event.thinking_delta("plan again"))
    app.on_event(Hcode::Loop::Event.text_delta("t2"))

    app.on_event(Hcode::Loop::Event.tool_call_start("c2", "Read", %({"filePath":"a.cr"})))
    app.on_event(Hcode::Loop::Event.tool_result("c2", "content", false))

    app.on_event(Hcode::Loop::Event.thinking_delta("final plan"))
    app.on_event(Hcode::Loop::Event.text_delta("t3"))

    summary = app.@messages.find { |m| m.role == "step_summary" }
    summary.should_not be_nil
    summary.not_nil!.thinking_count.should eq(2)
    summary.not_nil!.tool_count.should eq(1)

    visible_steps = app.@messages.count { |m| m.role == "thinking" || m.role == "tool" }
    visible_steps.should eq(2)
  end

  it "routes parallel tool results to the correct messages" do
    app = Hcode::TUI::App.new

    app.add_message("user", "hello")
    app.on_event(Hcode::Loop::Event.tool_call_start("c1", "Glob", %({"pattern":"*.cr"})))
    app.on_event(Hcode::Loop::Event.tool_call_start("c2", "Bash", %({"command":"echo hi"})))

    # Results arrive in reverse order; the handler must still find c1.
    app.on_event(Hcode::Loop::Event.tool_result("c2", "hi", false))
    app.on_event(Hcode::Loop::Event.tool_result("c1", "a.cr", false))

    glob = app.@messages.find { |m| m.role == "tool" && m.tool_call_id == "c1" }
    bash = app.@messages.find { |m| m.role == "tool" && m.tool_call_id == "c2" }

    glob.should_not be_nil
    bash.should_not be_nil
    glob.not_nil!.tool_result.should eq("a.cr")
    bash.not_nil!.tool_result.should eq("hi")
  end

  it "starts a fresh turn summary after a new user message" do
    app = Hcode::TUI::App.new
    app.keep_recent_steps = 1

    app.add_message("user", "first")
    2.times do |i|
      app.on_event(Hcode::Loop::Event.thinking_delta("t#{i}"))
      app.on_event(Hcode::Loop::Event.text_delta("x"))
    end

    app.add_message("user", "second")
    2.times do |i|
      app.on_event(Hcode::Loop::Event.thinking_delta("s#{i}"))
      app.on_event(Hcode::Loop::Event.text_delta("y"))
    end

    summaries = app.@messages.select { |m| m.role == "step_summary" }
    summaries.size.should eq(2)
  end

  it "renders the summary line in dim text" do
    app = Hcode::TUI::App.new
    summary = Hcode::TUI::Message.new("step_summary", "")
    summary.thinking_count = 3
    summary.tool_count = 2

    rendered = app.render_message(summary, 80).map { |l| app_strip_ansi(l) }
    text = rendered.join("\n")
    text.should contain("thinking 3 times")
    text.should contain("call 2 tools")
  end

  it "reads the keep threshold from the environment" do
    old = ENV["HCODE_TUI_KEEP_RECENT_STEPS"]?
    ENV["HCODE_TUI_KEEP_RECENT_STEPS"] = "5"
    begin
      app = Hcode::TUI::App.new
      app.keep_recent_steps.should eq(5)
    ensure
      if old
        ENV["HCODE_TUI_KEEP_RECENT_STEPS"] = old
      else
        ENV.delete("HCODE_TUI_KEEP_RECENT_STEPS")
      end
    end
  end

  it "falls back to the default for invalid environment values" do
    old = ENV["HCODE_TUI_KEEP_RECENT_STEPS"]?
    ENV["HCODE_TUI_KEEP_RECENT_STEPS"] = "not-a-number"
    begin
      app = Hcode::TUI::App.new
      app.keep_recent_steps.should eq(Hcode::TUI::App::DEFAULT_KEEP_RECENT_STEPS)
    ensure
      if old
        ENV["HCODE_TUI_KEEP_RECENT_STEPS"] = old
      else
        ENV.delete("HCODE_TUI_KEEP_RECENT_STEPS")
      end
    end
  end
end

describe Hcode::TUI::SelectList do
  it "shows all items when they fit within max_visible" do
    list = Hcode::TUI::SelectList.new
    list.show("Pick", ["a", "b", "c"])
    list.max_visible = 8
    start, count = list.visible_window
    start.should eq(0)
    count.should eq(3)
    list.scrolled_up?.should be_false
    list.scrolled_down?.should be_false
  end

  it "scrolls down when the selection moves past the viewport bottom" do
    list = Hcode::TUI::SelectList.new
    items = (1..12).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 7
    start, count = list.visible_window
    count.should eq(5)
    start.should eq(3)
    list.scrolled_up?.should be_true
    list.scrolled_down?.should be_true
  end

  it "scrolls to the last page when selection is near the end" do
    list = Hcode::TUI::SelectList.new
    items = (1..10).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 9
    start, count = list.visible_window
    start.should eq(5)
    count.should eq(5)
    list.scrolled_up?.should be_true
    list.scrolled_down?.should be_false
  end

  it "wraps around with scrolled_up false on selection 0" do
    list = Hcode::TUI::SelectList.new
    items = (1..10).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 0
    start, count = list.visible_window
    start.should eq(0)
    list.scrolled_up?.should be_false
    list.scrolled_down?.should be_true
  end

  it "resets scroll when show is called" do
    list = Hcode::TUI::SelectList.new
    items = (1..10).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 9
    list.visible_window
    list.show("Pick2", ["x", "y"])
    start, count = list.visible_window
    start.should eq(0)
    count.should eq(2)
  end
end

describe Hcode::TUI::App do
  it "rebuilds the transcript from a replayed context memory" do
    app = Hcode::TUI::App.new
    app.add_message("user", "old conversation that should be cleared")

    memory = Hcode::Context::Memory.new
    memory.add_user("hello")
    memory.add_assistant("world")
    app.load_transcript_from(memory)

    app.@messages.size.should eq(2)
    app.@messages[0].role.should eq("user")
    app.@messages[0].content.should eq("hello")
    app.@messages[1].role.should eq("assistant")
    app.@messages[1].content.should eq("world")
  end

  it "maps tool calls and tool results in the rebuilt transcript" do
    app = Hcode::TUI::App.new
    memory = Hcode::Context::Memory.new
    memory.add_user("list files")
    memory.add_assistant("", [Hcode::LLM::ToolCall.new(
      "tc1",
      Hcode::LLM::ToolCallFunction.new("Glob", %({"pattern":"*.cr"}))
    )])
    memory.add_tool_result("tc1", "a.cr\nb.cr")
    app.load_transcript_from(memory)

    roles = app.@messages.map(&.role)
    roles.should eq(["user", "tool"])
    tool_msg = app.@messages.find { |m| m.role == "tool" }.not_nil!
    tool_msg.tool_call_id.should eq("tc1")
    tool_msg.tool_name.should eq("Glob")
    tool_msg.tool_result.should eq("a.cr\nb.cr")
  end

  it "skips injection messages when rebuilding the transcript" do
    app = Hcode::TUI::App.new
    memory = Hcode::Context::Memory.new
    memory.add_injection("system prompt injected for tooling")
    memory.add_user("real user message")
    app.load_transcript_from(memory)

    app.@messages.size.should eq(1)
    app.@messages[0].role.should eq("user")
    app.@messages[0].content.should eq("real user message")
  end

  it "renders compaction summaries as system messages" do
    app = Hcode::TUI::App.new
    memory = Hcode::Context::Memory.new
    memory.add_user("first turn")
    memory.add_assistant("response")
    memory.apply_compaction("[summary of earlier turns]", [] of Hcode::Context::ContextMessage)
    app.load_transcript_from(memory)

    sys_msg = app.@messages.find { |m| m.role == "system" }
    sys_msg.should_not be_nil
    sys_msg.not_nil!.content.should contain("[compacted]")
  end
end

describe Hcode::TUI::App do
  it "splits a multi-line system message into one render line per source line" do
    # Regression: the renderer invariant is "one Array(String) entry == one
    # terminal row". A multi-line system message previously landed as a single
    # entry with embedded `\n`, which broke diff_render's row math and made the
    # screen scramble (the original /help bug).
    app = Hcode::TUI::App.new
    app.add_message("system", "first line\nsecond line\nthird line")

    rendered = app.render_message(app.@messages.last, 80)
    rendered.reject("").size.should eq(3)
    rendered.find { |l| l.includes?("first line") }.should_not be_nil
    rendered.find { |l| l.includes?("second line") }.should_not be_nil
    rendered.find { |l| l.includes?("third line") }.should_not be_nil
    # No rendered entry may carry an embedded newline.
    rendered.each { |l| l.should_not contain("\n") }
  end

  it "splits multi-line error and status messages the same way" do
    app = Hcode::TUI::App.new
    app.add_message("error", "boom-a\nboom-b")
    app.add_message("status", "s-a\ns-b")

    err = app.render_message(app.@messages[-2], 80).reject(&.empty?)
    err.size.should eq(2)
    err.each { |l| l.should_not contain("\n") }

    stat = app.render_message(app.@messages[-1], 80).reject(&.empty?)
    stat.size.should eq(2)
    stat.each { |l| l.should_not contain("\n") }
  end

  it "starts with the help panel hidden" do
    app = Hcode::TUI::App.new
    app.@help_panel.visible?.should be_false
  end
end

describe Hcode::TUI::HelpPanel do
  it "toggles visibility via show / hide" do
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    panel.visible?.should be_false
    panel.show
    panel.visible?.should be_true
    panel.hide
    panel.visible?.should be_false
  end

  it "dismisses on Esc, Enter, q, and Q" do
    [{Hcode::TUI::Key::Escape, "Esc"},
     {Hcode::TUI::Key::Enter, "Enter"}].each do |key, _|
      panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
      panel.show
      consumed = panel.handle_input(Hcode::TUI::KeyEvent.new(key))
      consumed.should be_true
      panel.visible?.should be_false
    end

    ['q', 'Q'].each do |c|
      panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
      panel.show
      panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Char, c)).should be_true
      panel.visible?.should be_false
    end
  end

  it "ignores unrelated printable keys without closing" do
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    panel.show
    panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Char, 'x')).should be_false
    panel.visible?.should be_true
  end

  it "scrolls down on Down / PageDown and clamps at the bottom" do
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    panel.max_visible = 5
    panel.show
    panel.render(80)

    # Pressing Down past the end must not blow up — render clamps the offset.
    50.times { panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Down)) }
    lines_after = panel.render(80)
    lines_after.size.should be > 0

    panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::PageDown))
    panel.render(80).size.should be > 0
  end

  it "never emits an embedded newline in any rendered line" do
    # The renderer-level invariant: every Array(String) entry is one terminal
    # row. Verify across several widths so truncation paths are exercised.
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    panel.show
    [200, 120, 80, 40, 20].each do |w|
      rendered = panel.render(w)
      rendered.each do |line|
        line.should_not contain("\n")
      end
    end
  end

  it "lists every registered slash command" do
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    # Expand the viewport so every command is on screen at once; the scroll
    # path is covered by the windowing spec below.
    panel.max_visible = 200
    panel.show
    body = panel.render(120).map { |l| help_strip_ansi(l) }.join("\n")
    Hcode::TUI::CommandRegistry::COMMANDS.each do |cmd|
      body.should contain(cmd.name)
    end
  end

  it "fires on_close when dismissed via a key" do
    fired = false
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    panel.on_close = -> { fired = true; nil }
    panel.show
    panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Escape))
    fired.should be_true
  end

  it "windows content to max_visible and shows a scroll indicator when overflowing" do
    panel = Hcode::TUI::HelpPanel.new(Hcode::TUI::Theme.dark)
    panel.max_visible = 5
    panel.show
    rendered = panel.render(120)
    body = rendered.map { |l| help_strip_ansi(l) }.join("\n")
    # The panel has more than 5 content lines, so the indicator must appear.
    body.should contain("showing")
    body.should contain("of")
  end

  # Fix 4 regression: cross-turn trim. Older turns (>keep_recent_turns)
  # collapse their thinking/tool blocks into a single step_summary so the
  # @messages array does not grow linearly across long sessions — see
  # plans/TOOLS-LEAKS.md §B1.
  describe "cross-turn trim (Fix 4)" do
    it "collapses thinking/tool blocks in turns older than keep_recent_turns" do
      app = Hcode::TUI::App.new
      app.keep_recent_steps = 100   # disable within-turn trim
      app.keep_recent_turns = 2

      # 5 turns, each with a tool block. Bash (not Read) so consecutive
      # calls don't get batched into a single read_group entry.
      5.times do |i|
        app.add_message("user", "u#{i}")
        app.on_event(Hcode::Loop::Event.tool_call_start("c#{i}", "Bash", %({"command":"echo #{i}"})))
        app.on_event(Hcode::Loop::Event.tool_result("c#{i}", "content #{i}", false))
        app.add_message("assistant", "a#{i}")
      end

      msgs = app.@messages

      # The three oldest turns (u0, u1, u2) must now each have a single
      # step_summary right after the user message and no surviving tool
      # blocks. The last 2 turns (u3, u4) keep their tool messages intact.
      index_of_user = ->(s : String) { msgs.index { |m| m.role == "user" && m.content == s } }

      ["u0", "u1", "u2"].each do |u|
        i = index_of_user.call(u)
        i.should_not be_nil
        msgs[i.not_nil! + 1].role.should eq("step_summary")
        u_num = u[1].to_i
        msgs.any? { |m| m.role == "tool" && m.tool_result == "content #{u_num}" }.should be_false
      end

      ["u3", "u4"].each do |u|
        u_num = u[1].to_i
        msgs.any? { |m| m.role == "tool" && m.tool_result == "content #{u_num}" }.should be_true
      end
    end

    it "folds counts from pre-existing step_summary when re-collapsing" do
      app = Hcode::TUI::App.new
      app.keep_recent_steps = 1   # aggressive within-turn trim
      app.keep_recent_turns = 1

      # Build two old turns with multiple Bash calls each — within-turn
      # trim will already produce a step_summary; cross-turn trim then
      # should still see and preserve those counts (no double counting,
      # no lost counts).
      2.times do |i|
        app.add_message("user", "u#{i}")
        3.times do |j|
          app.on_event(Hcode::Loop::Event.tool_call_start("c#{i}#{j}", "Bash", %({"command":"echo"})))
          app.on_event(Hcode::Loop::Event.tool_result("c#{i}#{j}", "r", false))
        end
      end
      app.add_message("user", "current")  # current turn

      msgs = app.@messages
      u0 = msgs.index { |m| m.role == "user" && m.content == "u0" }
      u0.should_not be_nil
      summary = msgs[u0.not_nil! + 1]
      summary.role.should eq("step_summary")
      summary.tool_count.should eq(3)
    end

    it "does nothing when total turns <= keep_recent_turns" do
      app = Hcode::TUI::App.new
      app.keep_recent_steps = 100
      app.keep_recent_turns = 50

      3.times do |i|
        app.add_message("user", "u#{i}")
        app.on_event(Hcode::Loop::Event.tool_call_start("c#{i}", "Bash", %({"command":"echo"})))
        app.on_event(Hcode::Loop::Event.tool_result("c#{i}", "r", false))
      end

      app.@messages.count(&.role.==("tool")).should eq(3)
      app.@messages.count(&.role.==("step_summary")).should eq(0)
    end

    it "can be disabled via keep_recent_turns = 0" do
      app = Hcode::TUI::App.new
      app.keep_recent_steps = 100
      app.keep_recent_turns = 0

      10.times do |i|
        app.add_message("user", "u#{i}")
        app.on_event(Hcode::Loop::Event.tool_call_start("c#{i}", "Bash", %({"command":"echo"})))
        app.on_event(Hcode::Loop::Event.tool_result("c#{i}", "r", false))
      end

      app.@messages.count(&.role.==("step_summary")).should eq(0)
      app.@messages.count(&.role.==("tool")).should eq(10)
    end
  end

  # Regression tests for the TUI_BUGS.md fixes (see TUI_FIXES.md).
  describe "TUI_BUGS fixes" do
    # BUG #2: wrap_text used .size (codepoints), so CJK text (1 codepoint =
    # 2 columns) overflowed. Now wraps by visible_width and hard-breaks
    # overwide tokens.
    it "wrap_text wraps CJK content by visible width" do
      app = Hcode::TUI::App.new
      # 20 Japanese chars = 40 columns; at cols=24 the bullet takes ~2 cols,
      # so the body must wrap into multiple lines each <= cols.
      cjk = "あ" * 20
      lines = app.render_message(Hcode::TUI::Message.new("user", cjk), 24)
      lines.each do |l|
        Hcode::TUI::CharWidth.visible_width(l).should be <= 24
      end
      lines.size.should be > 1
    end

    it "wrap_text hard-breaks a single overwide token" do
      app = Hcode::TUI::App.new
      # A single 40-char ASCII word (no spaces) wider than the column.
      word = "a" * 40
      lines = app.render_message(Hcode::TUI::Message.new("user", word), 10)
      lines.each do |l|
        Hcode::TUI::CharWidth.visible_width(l).should be <= 10
      end
      lines.size.should be > 1
    end

    # BUG #1 + #7: build_rendered_lines now truncates every line to `cols`
    # and appends a trailing SGR reset. Reach it via render_message output
    # piped through the same post-processing.
    it "build_rendered_lines truncates overwide lines to cols" do
      app = Hcode::TUI::App.new
      # Inject a long CJK line that a renderer would emit wider than cols.
      app.add_message("user", "あ" * 60)
      cols = 20
      new_lines, _ = app.build_rendered_lines(cols)
      new_lines.each do |l|
        Hcode::TUI::CharWidth.visible_width(l).should be <= cols
      end
    end

    it "build_rendered_lines ends every line with an SGR reset" do
      app = Hcode::TUI::App.new
      app.add_message("user", "hello")
      new_lines, _ = app.build_rendered_lines(80)
      new_lines.each do |l|
        l.should end_with(Hcode::TUI::ANSI.reset)
      end
    end

    # BUG #3: plan-box title with an ANSI Rejected badge miscomputed width
    # via .size, shrinking the top border. Now uses visible_len.
    it "render_plan_box keeps top and bottom borders aligned with ANSI title" do
      app = Hcode::TUI::App.new
      msg = Hcode::TUI::Message.new("plan_box", "do something")
      msg.plan_kind = "rejected"
      lines = app.render_plan_box(msg, 40)
      # Find the top (┌) and bottom (└) border lines; both end with ┐/┘.
      top = lines.find { |l| l.includes?('┌') }
      bottom = lines.find { |l| l.includes?('└') }
      top.should_not be_nil
      bottom.should_not be_nil
      Hcode::TUI::CharWidth.visible_width(top.not_nil!).should eq(
        Hcode::TUI::CharWidth.visible_width(bottom.not_nil!)
      )
    end

    # BUG: a long line inside the plan body (e.g. a code line) overflowed
    # content_width and pushed the right border onto the next terminal row,
    # reading as a stray blank line. Now clamped via slice_by_column.
    it "render_plan_box clamps body lines so the right border stays on-row" do
      app = Hcode::TUI::App.new
      long_line = "body = output[(idx + auto_marker.size)..].strip"
      msg = Hcode::TUI::Message.new("plan_box", "```crystal\n#{long_line}\n```")
      lines = app.render_plan_box(msg, 40)
      # Every body row (between top ┌ and bottom └) must contain both the
      # left and right border on the SAME line — no overflow wrap.
      body = lines.reject { |l| l.includes?('┌') || l.includes?('└') || l.empty? }
      body.each do |row|
        row.should contain('│')
        # Right border present exactly once on the row
        Hcode::TUI::CharWidth.visible_width(row).should be <= 40
      end
    end

    # BUG #4: single CJK grapheme at max_w=1 should not be split into an
    # empty chunk — it stays as one indivisible chunk.
    it "wrap_editor_line keeps an overwide single grapheme intact" do
      app = Hcode::TUI::App.new
      chunks = app.wrap_editor_line("あ", 1)
      chunks.size.should eq(1)
      Hcode::TUI::CharWidth.visible_width(chunks[0][0]).should eq(2)
    end

    # BUG #10: welcome box logo is 14 cols wide; clamp box_w so the border
    # doesn't collapse on very narrow terminals.
    it "render_welcome_box clamps box width to logo width" do
      app = Hcode::TUI::App.new
      lines = app.render_welcome_box(8)
      # The top border line should be at least 14 visible columns wide so
      # the logo fits inside without pushing the right border off-screen.
      top = lines.find { |l| l.includes?('╭') }
      top.should_not be_nil
      Hcode::TUI::CharWidth.visible_width(top.not_nil!).should be >= 14
    end
  end
end

describe Hcode::TUI::App do
  # SwarmMember is a struct. The terminal/progress handlers used to iterate it
  # with `each`, which yields a copy — so `sm.phase = ...` / `sm.ticks = ...`
  # mutated a throwaway clone and the array element stayed "Running" forever.
  # That kept @swarm_active true, driving an endless redraw loop that locked
  # terminal scroll even after every subagent had finished.
  describe "subagent lifecycle phase updates" do
    it "marks members Completed/Failed and clears swarm_active" do
      app = Hcode::TUI::App.new
      tc = "call_swarm_1"
      app.on_event(Hcode::Loop::Event.tool_call_start(tc, "AgentSwarm", "{}"))
      app.on_event(Hcode::Loop::Event.subagent_started(tc, "agent-a", 1, "item a"))
      app.on_event(Hcode::Loop::Event.subagent_started(tc, "agent-b", 2, "item b"))

      members = app.@messages.last.swarm_members
      members.size.should eq(2)
      members.all?(&.running?).should be_true
      app.@swarm_active.should be_true

      app.on_event(Hcode::Loop::Event.subagent_progress(tc, "agent-a", 5))
      app.on_event(Hcode::Loop::Event.subagent_completed(tc, "agent-a"))
      app.on_event(Hcode::Loop::Event.subagent_failed(tc, "agent-b", "boom"))

      members = app.@messages.last.swarm_members
      members[0].phase.should eq("Completed")
      members[0].ticks.should eq(5)
      members[1].phase.should eq("boom")
      members.all?(&.done?).should be_true
      app.@swarm_active.should be_false
    end
  end
end
