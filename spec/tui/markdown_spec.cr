require "../spec_helper"

# Helpers at top level (Crystal doesn't allow def inside describe)
def md_strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

def md_render_text(md : Hcode::TUI::Markdown, text : String, width = 80) : String
  md.render(text, width).map { |l| md_strip_ansi(l) }.join('\n')
end

def md_render_raw(md : Hcode::TUI::Markdown, text : String, width = 80) : Array(String)
  md.render(text, width)
end

describe Hcode::TUI::Markdown do
  md = Hcode::TUI::Markdown.new(Hcode::TUI::Theme.dark)

  # =========================================================================
  # Inline formatting
  # =========================================================================

  describe "inline bold" do
    it "renders **bold** with ANSI bold code" do
      joined = md_render_raw(md, "This is **bold** text").join
      joined.should contain("\e[1m")
      md_strip_ansi(joined).should contain("bold")
    end

    it "renders __bold__ with ANSI bold code" do
      joined = md_render_raw(md, "This is __bold__ text").join
      joined.should contain("\e[1m")
      md_strip_ansi(joined).should contain("bold")
    end

    it "renders both bold and italic in same line" do
      joined = md_render_raw(md, "**bold** and *italic*").join
      joined.should contain("\e[1m")
      joined.should contain("\e[3m")
    end
  end

  describe "inline italic" do
    it "renders *italic* with ANSI italic code" do
      joined = md_render_raw(md, "This is *italic* text").join
      joined.should contain("\e[3m")
      md_strip_ansi(joined).should contain("italic")
    end

    it "renders _italic_ with ANSI italic code" do
      joined = md_render_raw(md, "This is _italic_ text").join
      joined.should contain("\e[3m")
      md_strip_ansi(joined).should contain("italic")
    end

    it "does not trigger italic for intraword underscores (foo_bar_baz)" do
      joined = md_render_raw(md, "foo_bar_baz").join
      joined.should_not contain("\e[3m")
    end

    it "does not trigger italic for intraword asterisks (foo*bar*baz)" do
      joined = md_render_raw(md, "foo*bar*baz").join
      joined.should_not contain("\e[3m")
    end
  end

  describe "inline strikethrough" do
    it "renders ~~strikethrough~~ with ANSI dim code" do
      joined = md_render_raw(md, "This is ~~struck~~ text").join
      joined.should contain("\e[2m")
      md_strip_ansi(joined).should contain("struck")
    end
  end

  describe "inline code" do
    it "renders `code` with color code" do
      joined = md_render_raw(md, "Use `crystal build` to compile").join
      md_strip_ansi(joined).should contain("crystal build")
    end
  end

  describe "links" do
    it "renders [text](url) with underline" do
      joined = md_render_raw(md, "[HCode](https://example.com)").join
      joined.should contain("\e[4m")
      md_strip_ansi(joined).should contain("HCode")
    end

    it "shows URL when link text differs from href" do
      text = md_render_text(md, "[Click](https://example.com)")
      text.should contain("https://example.com")
    end

    it "does not show URL when link text equals href" do
      text = md_render_text(md, "[https://example.com](https://example.com)")
      text.should_not contain("(https://example.com)")
    end
  end

  describe "escape sequences" do
    it "renders escaped asterisk as literal" do
      text = md_render_text(md, "This is \\*not bold\\* text")
      text.should contain("*not bold*")
    end

    it "renders escaped underscore as literal" do
      text = md_render_text(md, "foo\\_bar")
      text.should contain("foo_bar")
    end

    it "renders escaped backtick as literal" do
      text = md_render_text(md, "foo\\`bar")
      text.should contain("foo`bar")
    end
  end

  describe "streaming safety" do
    it "renders unmatched ** as plain text" do
      text = md_render_text(md, "This is **not closed")
      text.should contain("**not closed")
    end

    it "renders unmatched ` as plain text" do
      text = md_render_text(md, "code `not closed")
      text.should contain("`not closed")
    end

    it "renders unmatched ~~ as plain text" do
      text = md_render_text(md, "~~not closed")
      text.should contain("~~not closed")
    end
  end

  # =========================================================================
  # Block-level rendering
  # =========================================================================

  describe "headings" do
    it "renders H1 with bold and underline" do
      joined = md_render_raw(md, "# Title").join
      joined.should contain("\e[1m")
      joined.should contain("\e[4m")
      md_strip_ansi(joined).should contain("Title")
    end

    it "renders H2 with bold (no underline)" do
      joined = md_render_raw(md, "## Section").join
      joined.should contain("\e[1m")
      joined.should_not contain("\e[4m")
    end

    it "renders H3+ with hash prefix" do
      text = md_render_text(md, "### Subsection")
      text.should contain("### Subsection")
    end

    it "renders H4 with hash prefix" do
      text = md_render_text(md, "#### Deep heading")
      text.should contain("#### Deep heading")
    end

    it "handles all heading levels 1-6" do
      (1..6).each do |level|
        hashes = "#" * level
        text = md_render_text(md, "#{hashes} Heading#{level}")
        md_strip_ansi(text).should contain("Heading#{level}")
      end
    end
  end

  describe "horizontal rules" do
    it "renders --- as a horizontal rule" do
      joined = md_render_raw(md, "---").join
      md_strip_ansi(joined).should match(/─{10,}/)
    end

    it "renders *** as a horizontal rule" do
      joined = md_render_raw(md, "***").join
      md_strip_ansi(joined).should match(/─{10,}/)
    end

    it "renders ___ as a horizontal rule" do
      joined = md_render_raw(md, "___").join
      md_strip_ansi(joined).should match(/─{10,}/)
    end
  end

  describe "lists" do
    it "renders unordered list with bullet" do
      text = md_render_text(md, "- item one\n- item two")
      text.should contain("•")
      text.should contain("item one")
      text.should contain("item two")
    end

    it "renders ordered list with numbers" do
      text = md_render_text(md, "1. first\n2. second\n3. third")
      text.should contain("1.")
      text.should contain("2.")
      text.should contain("3.")
    end

    it "indents ordered list items with a 2-space margin like unordered" do
      ordered = md_render_text(md, "1. first").split('\n').reject(&.empty?).first
      unordered = md_render_text(md, "- first").split('\n').reject(&.empty?).first
      ordered.should start_with("  1.")
      unordered.should start_with("  •")
    end

    it "supports + as unordered marker" do
      text = md_render_text(md, "+ plus item")
      text.should contain("•")
    end

    it "supports * as unordered marker" do
      text = md_render_text(md, "* star item")
      text.should contain("•")
    end
  end

  describe "nested lists" do
    it "indents nested items deeper than parent" do
      text = md_render_text(md, "- top\n  - nested")
      lines = text.split('\n').reject(&.empty?)
      top_line = lines.find { |l| l.includes?("top") }.not_nil!
      nested_line = lines.find { |l| l.includes?("nested") }.not_nil!
      nested_indent = nested_line.size - nested_line.lstrip.size
      top_indent = top_line.size - top_line.lstrip.size
      nested_indent.should be > top_indent
    end

    it "handles 3 levels of nesting" do
      text = md_render_text(md, "- L1\n  - L2\n    - L3")
      lines = text.split('\n').reject(&.empty?)
      l1 = lines.find { |l| l.includes?("L1") }.not_nil!
      l3 = lines.find { |l| l.includes?("L3") }.not_nil!
      l3_indent = l3.size - l3.lstrip.size
      l1_indent = l1.size - l1.lstrip.size
      l3_indent.should be > l1_indent
    end
  end

  describe "task lists" do
    it "renders checked task with [x]" do
      text = md_render_text(md, "- [x] done task")
      text.should contain("[x]")
      text.should contain("done task")
    end

    it "renders unchecked task with [ ]" do
      text = md_render_text(md, "- [ ] pending task")
      text.should contain("[ ]")
      text.should contain("pending task")
    end

    it "renders capital [X] as checked" do
      text = md_render_text(md, "- [X] also done").downcase
      text.should contain("[x]")
    end
  end

  describe "tables" do
    it "renders table with Unicode borders" do
      text = md_render_text(md, "| A | B |\n|---|---|\n| 1 | 2 |")
      text.should contain("┌")
      text.should contain("┐")
      text.should contain("└")
      text.should contain("┘")
      text.should contain("│")
    end

    it "renders header row content" do
      text = md_render_text(md, "| Name | Age |\n|------|-----|\n| Alice | 30 |")
      text.should contain("Name")
      text.should contain("Age")
    end

    it "renders data rows" do
      text = md_render_text(md, "| Name | Age |\n|------|-----|\n| Alice | 30 |")
      text.should contain("Alice")
      text.should contain("30")
    end

    it "includes separator line" do
      text = md_render_text(md, "| A | B |\n|---|---|\n| 1 | 2 |")
      text.should contain("├")
      text.should contain("┼")
      text.should contain("┤")
    end

    it "handles table followed by text" do
      text = md_render_text(md, "| A |\n|---|\n| 1 |\n\nAfter table")
      text.should contain("After table")
    end

    it "handles streaming partial table (no closing)" do
      text = md_render_text(md, "| A | B |\n|---|---|\n| 1 | 2 |")
      text.should contain("┌")
    end

    it "keeps columns aligned when a cell contains a wide emoji" do
      text = md_render_text(md, "| Feature | Status |\n|---|---|\n| A | \u274C |\n| B | ok |", 40)
      lines = text.split('\n')
      # The right border must sit at the same display column on every row.
      right_col = lines.map do |l|
        idx = l.rindex('│')
        idx.nil? ? nil : Hcode::TUI::CharWidth.visible_width(l[0...idx])
      end.compact
      right_col.uniq.size.should eq(1)
    end

    it "pads a text-default emoji (⚠) by its real width so borders align" do
      # Regression for the ⚠-row drift: ⚠ (U+26A0) renders at width 1, so its
      # cell must receive one more padding space than a width-2 glyph (❌) in
      # the same column. Asserted on raw space counts (byte-level), not via
      # visible_width, since visible_width shares the renderer's width model
      # and would otherwise mask the bug.
      text = md_render_text(md, "| Status |\n|---|\n| \u26A0 |\n| \u274C |", 40)
      lines = text.split('\n').select(&.includes?('│'))
      warn_line = lines.find(&.includes?("\u26A0")).not_nil!
      cross_line = lines.find(&.includes?("\u274C")).not_nil!
      # Column width = max("Status"=6, ⚠=1, ❌=2) = 6. Trailing spaces between
      # the glyph and the final │ = (6 - glyph width) + 1 (the " │" join gap).
      warn_pad = warn_line.match(/⚠( *)│\z/).not_nil![1].size
      cross_pad = cross_line.match(/❌( *)│\z/).not_nil![1].size
      warn_pad.should eq(6)  # 6 - 1 (⚠ width) + 1
      cross_pad.should eq(5) # 6 - 2 (❌ width) + 1
    end

    it "keeps columns aligned when a cell contains CJK characters" do
      text = md_render_text(md, "| Name | Notes |\n|---|---|\n| Alice | \u4f60\u597d |", 40)
      lines = text.split('\n')
      right_col = lines.map do |l|
        idx = l.rindex('│')
        idx.nil? ? nil : Hcode::TUI::CharWidth.visible_width(l[0...idx])
      end.compact
      right_col.uniq.size.should eq(1)
    end

    it "indents every table line with a 2-space margin" do
      text = md_render_text(md, "| A | B |\n|---|---|\n| 1 | 2 |")
      text.split('\n').reject(&.empty?).each do |l|
        l.should start_with("  ")
      end
    end

    it "wraps overflowing cells instead of breaking borders" do
      input = "| File | Purpose |\n|------|---------|\n| `src/hcode.cr` | Entry point for the CLI application |"
      lines = md_render_text(md, input, 30)
      # Every line should have the same visible width (no overflow).
      widths = lines.split('\n').reject(&.empty?).map do |l|
        Hcode::TUI::CharWidth.visible_width(l)
      end
      widths.uniq.size.should eq(1)
      # The right border │ must appear on every content line.
      lines.split('\n').select(&.includes?('│')).size.should be > 2
    end

    it "falls back to plain text when terminal is too narrow for a table" do
      input = "| A | B | C | D |\n|---|---|---|---|\n| 1 | 2 | 3 | 4 |"
      text = md_render_text(md, input, 10)
      # No Unicode box-drawing characters — table rendering was skipped.
      text.should_not contain("┌")
      text.should_not contain("│")
    end

    it "renders separators between data rows" do
      input = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |"
      text = md_render_text(md, input, 40)
      # Header separator (├) + two inter-row separators = 3 ├ lines.
      text.count('├').should eq(3)
    end

    it "renders inline code in cells without showing backticks" do
      input = "| File | Purpose |\n|------|---------|\n| `src/hcode.cr` | Entry point |"
      joined = md_render_raw(md, input, 60).join
      # Inline code should be styled with ANSI color, not literal backticks.
      joined.should contain("\e[38;5;")
      stripped = md_strip_ansi(joined)
      stripped.should_not contain("`src/hcode.cr`")
      stripped.should contain("src/hcode.cr")
    end
  end

  describe "blockquotes" do
    it "renders > with vertical bar prefix" do
      text = md_render_text(md, "> A quote")
      text.should contain("│")
      text.should contain("A quote")
    end

    it "renders multiple consecutive > lines without separators between them" do
      text = md_render_text(md, "> Line 1\n> Line 2\n> Line 3")
      lines = text.split('\n').reject(&.empty?)
      lines.size.should eq(3)
      lines.each { |l| l.should contain("│") }
    end
  end

  describe "code blocks" do
    it "renders fenced code block" do
      text = md_render_text(md, "```crystal\nputs \"hello\"\n```")
      text.should contain("puts")
      text.should contain("hello")
    end

    it "shows language label" do
      text = md_render_text(md, "```python\nprint('hi')\n```")
      text.should contain("python")
    end

    it "highlights keywords in crystal code" do
      joined = md_render_raw(md, "```crystal\ndef foo\n```").join
      joined.should contain("\e[1m")
    end

    it "does not corrupt ANSI escapes when highlighting code" do
      # Keywords, strings and numbers together used to make the number pass
      # re-match the digits living inside color codes already inserted by
      # earlier passes (the `38;5;N` in `\e[38;5;N m`), splitting them into
      # broken CSI fragments that printed as stray `38;5;80m` text.
      joined = md_render_raw(md, "```crystal\ndef foo(x : Int32)\n  puts \"hi 42\" # note\nend\n```").join
      stripped = md_strip_ansi(joined)
      stripped.should_not contain("38;5;")
      stripped.should contain("def")
      stripped.should contain("42")
      stripped.should contain("hi 42")
    end
  end

  describe "paragraph spacing" do
    it "adds blank line between paragraphs" do
      lines = md.render("First paragraph.\n\nSecond paragraph.", 80)
      has_blank = lines.any?(&.empty?)
      has_blank.should be_true
    end

    it "does not add separator within a single paragraph" do
      lines = md.render("Just one paragraph here.", 80)
      has_blank = lines.any?(&.empty?)
      has_blank.should be_false
    end

    it "adds blank line between paragraph and list" do
      lines = md.render("Intro text.\n\n- item 1\n- item 2", 80)
      joined = lines.map { |l| md_strip_ansi(l) }.join('\n')
      joined.should contain("Intro text")
      joined.should contain("item 1")
    end
  end

  # =========================================================================
  # Infrastructure: wrapping and visible width
  # =========================================================================

  describe "text wrapping" do
    it "wraps long lines to specified width" do
      long = "This is a very long sentence that definitely exceeds twenty columns."
      lines = md.render(long, 20)
      lines.each do |l|
        vw = md_strip_ansi(l).size
        vw.should be <= 25
      end
    end

    it "does not wrap short lines" do
      lines = md.render("Short.", 80)
      lines.size.should eq(1)
    end

    it "preserves ANSI codes across wrapped lines" do
      long = "**#{"bold word " * 20}**"
      joined = md_render_raw(md, long, 30).join
      joined.should contain("\e[1m")
    end
  end

  describe "empty and edge cases" do
    it "handles empty string" do
      lines = md.render("", 80)
      lines.size.should be <= 1
    end

    it "handles single newline" do
      lines = md.render("\n", 80)
      lines.should_not be_nil
    end

    it "handles whitespace-only input" do
      lines = md.render("   ", 80)
      lines.should_not be_nil
    end

    it "handles very narrow width" do
      lines = md.render("word", 1)
      lines.should_not be_nil
    end
  end

  describe "mixed content" do
    it "renders heading followed by paragraph" do
      text = md_render_text(md, "# Title\n\nSome content here.")
      text.should contain("Title")
      text.should contain("Some content here")
    end

    it "renders list followed by code block" do
      text = md_render_text(md, "- item\n\n```crystal\nputs 1\n```")
      text.should contain("item")
      text.should contain("puts")
    end

    it "renders blockquote followed by paragraph" do
      text = md_render_text(md, "> quoted\n\nNormal text")
      text.should contain("quoted")
      text.should contain("Normal text")
    end

    it "handles complex markdown with multiple elements" do
      input = <<-MD
        # Project Title

        This is a **bold** paragraph with `code` and *italic*.

        ## Features

        - Feature one
        - Feature two
          - Nested feature
        - [x] Completed task

        | Col1 | Col2 |
        |------|------|
        | a    | b    |

        > A blockquote

        ```crystal
        puts "hello"
        ```
      MD

      text = md_render_text(md, input, 80)
      text.should contain("Project Title")
      text.should contain("bold")
      text.should contain("Features")
      text.should contain("Feature one")
      text.should contain("Nested feature")
      text.should contain("[x]")
      text.should contain("┌")
      text.should contain("blockquote")
      text.should contain("puts")
    end
  end
end
