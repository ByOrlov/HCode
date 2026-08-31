require "../spec_helper"
require "../../src/tui/diff"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"

# Streaming-markdown shrink reproducers.
#
# The streaming assistant text is re-rendered through Markdown#render every
# frame over the FULL accumulated buffer. The markdown interpretation of
# already-received tokens is not monotonic in line count:
#
#   * While an inline delimiter pair is still open (`**`, `*`, `~~`, `` ` ``)
#     the renderer falls back to raw text, which is WIDER than the styled
#     result. When the closing delimiter arrives the paragraph can re-wrap
#     onto FEWER lines and the Active zone shrinks.
#   * While an ordered-list marker streams in, the bare digit ("\n2") renders
#     as a paragraph for one frame; the next frame re-absorbs it into the list
#     (`strip_streaming_incomplete` drops the trailing marker, but the digit
#     line from the PREVIOUS frame already vanished).
#
# Both are the same class the list-marker hack papered over for "-" markers —
# and both make SyncBugsCount fire. These specs stream markdown one character
# at a time through the real event → render path and assert the invariant the
# two-zone model depends on:
#
#   During a single streaming block, the active-zone height must never
#   decrease from one frame to the next.
#
# Geometry: cols=80 → render_streaming_text renders markdown at width 75,
# paragraphs wrap at 73 (`para_width = width - 2`). The corpus strings are
# tuned so the raw (delimiter-open) form crosses that boundary and the styled
# (closed) form fits under it.

# Fresh app in streaming state. App#stop clears @running so the synchronous
# render_now() triggered by on_event stays silent once @first_render is
# cleared (specs render explicitly via build_rendered_lines* / render_to).
private def stream_app : H2code::TUI::App
  app = H2code::TUI::App.new
  app.stop
  app.on_event(H2code::Loop::Event.step_begin(0))
  app
end

# Stream `text` into `app` one char at a time as text_delta events, rendering
# a frame after each char. Returns the active-zone height after each frame.
private def stream_heights(app : H2code::TUI::App, text : String, cols : Int32 = 80) : Array(Int32)
  heights = [] of Int32
  text.each_char do |ch|
    app.on_event(H2code::Loop::Event.text_delta(ch.to_s))
    _log, active, _ed = app.build_rendered_lines_split(cols)
    heights << active.size
  end
  heights
end

# Assert the height sequence never decreases; fail with frame context.
private def assert_never_shrinks(heights : Array(Int32)) : Nil
  heights.each_with_index do |h, i|
    next if i == 0 || h >= heights[i - 1]
    fail("active zone shrank at char #{i} (#{heights[i - 1]} → #{h}) heights=#{heights}")
  end
end

# Index of the first frame where the active zone shrank, or nil.
private def first_shrink(heights : Array(Int32)) : Int32?
  heights.each_with_index do |h, i|
    return i if i > 0 && h < heights[i - 1]
  end
  nil
end

# Strip ANSI SGR sequences so transcript assertions compare visible text only.
private def strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

describe "Streaming markdown — active zone must not shrink" do
  # ── Inline bold: raw `**xxx…` keeps the opener; closed `**xxx**` drops it ──
  # 72 'a' + "**" prefix = 74 raw cols → 2 wrapped lines; closed bold renders
  # 72 cols → 1 line. The shrink fires on the closing "**".
  it "bold completion must not shrink the streaming block" do
    heights = stream_heights(stream_app, "**#{"a" * 72}**")
    assert_never_shrinks(heights)
  end

  # ── Inline code span: raw `` `xxx… `` keeps the backtick; closed drops it ──
  # 73 'b' + opening backtick = 74 raw cols → 2 lines; closed code span renders
  # 73 cols → 1 line.
  it "inline code completion must not shrink the streaming block" do
    heights = stream_heights(stream_app, "`#{"b" * 73}`")
    assert_never_shrinks(heights)
  end

  # ── Italic: raw `*xxx…` keeps the asterisk; closed drops it ──
  # 73 'c' + "*" = 74 raw cols → 2 lines; closed italic renders 73 → 1 line.
  it "italic completion must not shrink the streaming block" do
    heights = stream_heights(stream_app, "*#{"c" * 73}*")
    assert_never_shrinks(heights)
  end

  # ── Strikethrough: raw `~~xxx…` keeps the opener; closed drops it ──
  # 72 'e' + "~~" = 74 raw cols → 2 lines; closed strikethrough renders 72 → 1.
  it "strikethrough completion must not shrink the streaming block" do
    heights = stream_heights(stream_app, "~~#{"e" * 72}~~")
    assert_never_shrinks(heights)
  end

  # ── Ordered list: the bare digit transient ──
  # While "2" streams in (before the "." arrives) it renders as a paragraph
  # separated from the previous list item by a blank line; the next char
  # re-absorbs it into the list and the block loses a line. This is the same
  # class as the "-" hack but NOT covered by it: strip_streaming_incomplete
  # drops the trailing "2." marker, yet the "2" paragraph line from the
  # previous frame still vanishes.
  it "ordered-list digit transient must not shrink the streaming block" do
    heights = stream_heights(stream_app, "1. first\n2. second\n3. third\n")
    assert_never_shrinks(heights)
  end

  # ── Link: raw `[see](url` vs closed `see (url)` ──
  # Before the ")" arrives the raw form is "[see](url" (6 + url cols); the
  # closed form is "see (url)" (6 + url cols) — equal width, so today this
  # case happens to hold. Kept as coverage for the invariant.
  it "link completion must not shrink the streaming block" do
    url = "https://example.com/" + "d" * 47 # 67 chars total
    heights = stream_heights(stream_app, "[see](#{url})")
    assert_never_shrinks(heights)
  end

  # ── Blocks that re-interpret in place (documentation coverage) ──
  # Heading, blockquote, code fence and table transitions change how earlier
  # lines render but must never reduce the block height either.
  it "block transitions must not shrink the streaming block" do
    [
      "Intro paragraph.\n\n## Heading appears mid-stream\n\nBody text.\n",
      "> quoted line one\n> quoted line two\n",
      "```crystal\nputs \"hi\"\n```\n",
      "| a | b |\n|---|---|\n| 1 | 2 |\n",
      "- [ ] task one\n- [x] task two\n",
    ].each do |text|
      heights = stream_heights(stream_app, text)
      assert_never_shrinks(heights)
    end
  end

  # ── End-to-end through the incremental renderer + screen mock ──
  # Stream into the TerminalMock and require the final visible transcript to
  # be free of duplicated or stale streaming content.
  it "bold completion streams cleanly through the incremental renderer" do
    app = stream_app
    mock = H2code::TUI::TerminalMock.new(rows: 24, cols: 80)
    text = "**#{"a" * 72}** done"

    text.each_char do |ch|
      app.on_event(H2code::Loop::Event.text_delta(ch.to_s))
      app.render_to(mock)
    end

    transcript = mock.visible_rows.map { |l| strip_ansi(l) }
    # The styled "aaa…" body must appear exactly once across the transcript.
    body = "a" * 40
    hits = transcript.count { |l| l.includes?(body) }
    hits.should eq(1)
  end

  # ── Aggregate: no SyncBug across a mixed realistic corpus ──
  it "keeps SyncBugsCount at zero across char-by-char markdown streaming" do
    corpus = [
      "## Heading appears mid-stream\n\nSome paragraph text under it.\n",
      "1. first\n2. second\n3. third\n",
      "- [ ] task one\n- [x] task two\n",
      "> quoted line one\n> quoted line two\n",
      "```crystal\nputs \"hi\"\n```\n",
      "| a | b |\n|---|---|\n| 1 | 2 |\n",
      "**#{"a" * 72}**",
      "`#{"b" * 73}`",
      "~~#{"e" * 72}~~",
      "*#{"c" * 73}*",
    ]
    corpus.each do |text|
      app = stream_app
      text.each_char do |ch|
        app.on_event(H2code::Loop::Event.text_delta(ch.to_s))
        app.build_rendered_lines(80)
      end
      app.@sync_bugs_count.should eq(0), "corpus=#{text[0, 24].inspect}"
    end
  end

  # ── Finalization: migration to the log must not shrink combined coverage ──
  # The padded block can be taller than the finalized message renders in the
  # log; flush_streaming_text! compensates the deficit with spacer lines so
  # SyncBugsCount stays at zero through the migration.
  it "finalizing the stream keeps combined coverage (no SyncBug at migration)" do
    app = stream_app
    text = "**#{"a" * 72}** done"
    text.each_char do |ch|
      app.on_event(H2code::Loop::Event.text_delta(ch.to_s))
      app.build_rendered_lines(80)
    end
    app.on_event(H2code::Loop::Event.assistant_text(""))
    app.build_rendered_lines(80)

    app.@sync_bugs_count.should eq(0)
    app.@streaming_text.should be_empty
    app.@streaming_hwm.should eq(0)
    app.@messages.any? { |m| m.role == "assistant" }.should be_true
  end
end
