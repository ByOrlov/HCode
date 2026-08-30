require "../spec_helper"
require "../../src/tui/diff"

describe H2code::TUI::DiffComputer do
  it "returns only changed lines (no context)" do
    changed = H2code::TUI::DiffComputer.changed_lines("a\nb\nc", "a\nB\nc")
    # Only the changed line; context lines (a, c) are dropped.
    changed.all?(&.kind.context?).should be_false
    changed.any?(&.kind.delete?).should be_true
    changed.any?(&.kind.add?).should be_true
  end

  it "detects pure additions" do
    changed = H2code::TUI::DiffComputer.changed_lines("a\nb", "a\nb\nc")
    adds = changed.select(&.kind.add?)
    adds.size.should eq(1)
    adds.first.content.should eq("c")
    changed.any?(&.kind.delete?).should be_false
  end

  it "detects pure deletions" do
    changed = H2code::TUI::DiffComputer.changed_lines("a\nb\nc", "a\nb")
    dels = changed.select(&.kind.delete?)
    dels.size.should eq(1)
    dels.first.content.should eq("c")
  end

  it "pairs delete+add and attaches a highlight span" do
    changed = H2code::TUI::DiffComputer.changed_lines("foo = bar", "foo = baz")
    changed.any?(&.kind.delete?).should be_true

    add = changed.find!(&.kind.add?)
    span = add.highlight
    span.should_not be_nil
    # The changed region in "foo = baz" is "z" at the end (prefix "foo = ba").
    if s = span
      s.start.should eq(8)
      s.length.should eq(1)
    end
  end

  it "returns no highlight when the whole line changed" do
    changed = H2code::TUI::DiffComputer.changed_lines("old", "new")
    add = changed.find!(&.kind.add?)
    add.highlight.should be_nil
  end

  it "handles identical text (no changes)" do
    changed = H2code::TUI::DiffComputer.changed_lines("same\nlines", "same\nlines")
    changed.should be_empty
  end

  it "handles empty old text" do
    changed = H2code::TUI::DiffComputer.changed_lines("", "new line")
    # "".split('\n') = [""] → one delete of empty + one add.
    changed.size.should eq(2)
    changed.any?(&.kind.add?).should be_true
    changed.find!(&.kind.add?).content.should eq("new line")
  end

  it "highlights only the middle changed words" do
    changed = H2code::TUI::DiffComputer.changed_lines(
      "def hello_world",
      "def goodbye_world",
    )
    add = changed.find!(&.kind.add?)
    span = add.highlight || raise "highlight should not be nil"
    # prefix "def " (4 chars), changed "goodbye", suffix "_world"
    add.content[span.start, span.length].should eq("goodbye")
  end
end
