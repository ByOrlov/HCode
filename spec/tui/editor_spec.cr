require "../spec_helper"
require "../../src/tui/component"
require "../../src/tui/editor"

describe Hcode::TUI::Editor do
  it "deletes one character on plain Backspace" do
    editor = Hcode::TUI::Editor.new
    editor.set("hello world")
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace))
    editor.text.should eq("hello worl")
  end

  it "deletes the previous word on Alt+Backspace" do
    editor = Hcode::TUI::Editor.new
    editor.set("hello world foo")
    ev = Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace)
    ev.alt = true
    editor.handle_input(ev)
    editor.text.should eq("hello world ")
  end

  it "skips whitespace before killing the previous word" do
    editor = Hcode::TUI::Editor.new
    editor.set("hello world   ")
    ev = Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace)
    ev.alt = true
    editor.handle_input(ev)
    editor.text.should eq("hello ")
  end

  it "deletes a single word when cursor is mid-line" do
    editor = Hcode::TUI::Editor.new
    editor.set("hello world foo")
    editor.set("hello world") # cursor at end of "hello world"
    ev = Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace)
    ev.alt = true
    editor.handle_input(ev)
    editor.text.should eq("hello ")
  end

  it "does nothing at start of the first line" do
    editor = Hcode::TUI::Editor.new
    editor.set("hello")
    editor.cursor_position.should eq({0, 5})
    # Move cursor to start
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Home))
    ev = Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace)
    ev.alt = true
    editor.handle_input(ev)
    editor.text.should eq("hello")
  end

  # --- Paste marker atomic behavior (mirrors the JS editor tests) ---

  it "collapses a large paste into a marker" do
    editor = Hcode::TUI::Editor.new
    editor.handle_input(Hcode::TUI::KeyEvent.char('A'))
    editor.insert_paste_marker("line1\nline2\nline3", 3)
    editor.text.should eq("A[paste #1 +3 lines]")
    editor.pasted?.should be_true
  end

  it "expands paste markers on submit!" do
    editor = Hcode::TUI::Editor.new
    editor.insert_paste_marker("hello\nworld", 2)
    result = editor.submit!
    result.should eq("hello\nworld")
    editor.pasted?.should be_false
  end

  it "does not delete the marker while removing typed text after it" do
    editor = Hcode::TUI::Editor.new
    editor.handle_input(Hcode::TUI::KeyEvent.char('A'))
    editor.insert_paste_marker("multi\nline\nblock", 3)
    # Marker is now after "A"; cursor sits right after the marker.
    editor.handle_input(Hcode::TUI::KeyEvent.char('B'))
    editor.handle_input(Hcode::TUI::KeyEvent.char('C'))
    editor.text.should eq("A[paste #1 +3 lines]BC")

    # Backspace twice removes only "C" then "B" — marker stays intact.
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace))
    editor.text.should eq("A[paste #1 +3 lines]B")
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace))
    editor.text.should eq("A[paste #1 +3 lines]")
    editor.pasted?.should be_true
    # Cursor is now right after the marker.
    editor.cursor_position.should eq({0, editor.text.size})
  end

  it "deletes the whole marker atomically with backspace" do
    editor = Hcode::TUI::Editor.new
    editor.handle_input(Hcode::TUI::KeyEvent.char('A'))
    editor.insert_paste_marker("multi\nline\nblock", 3)
    editor.handle_input(Hcode::TUI::KeyEvent.char('B'))
    # Cursor is at end ("...lines]B"); move left past B to sit right after marker.
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Left))
    editor.cursor_position[1].should eq(editor.text.size - 1)

    # One backspace deletes the entire marker at once.
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace))
    editor.text.should eq("AB")
    editor.pasted?.should be_false
  end

  it "deletes the whole marker atomically with forward delete" do
    editor = Hcode::TUI::Editor.new
    editor.handle_input(Hcode::TUI::KeyEvent.char('A'))
    editor.insert_paste_marker("multi\nline\nblock", 3)
    editor.handle_input(Hcode::TUI::KeyEvent.char('B'))
    # Move cursor to the start of the marker (after "A").
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Home))  # col 0
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Right)) # past "A"

    # Forward delete removes the entire marker.
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Delete))
    editor.text.should eq("AB")
    editor.pasted?.should be_false
  end

  it "jumps over the marker with left/right arrows" do
    editor = Hcode::TUI::Editor.new
    editor.handle_input(Hcode::TUI::KeyEvent.char('A'))
    editor.insert_paste_marker("multi\nline\nblock", 3)
    editor.handle_input(Hcode::TUI::KeyEvent.char('B'))
    marker_len = editor.text.size - 2 # "A" + marker + "B"

    # Cursor at end (after "B"); first Left steps onto "B".
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Left))
    editor.cursor_position[1].should eq(editor.text.size - 1)
    # Second Left jumps over the whole marker in one step.
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Left))
    editor.cursor_position[1].should eq(1) # right after "A", before marker

    # One Right jumps back over the whole marker.
    editor.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Right))
    editor.cursor_position[1].should eq(1 + marker_len)
  end

  it "expands markers in place (Ctrl+E)" do
    editor = Hcode::TUI::Editor.new
    editor.handle_input(Hcode::TUI::KeyEvent.char('X'))
    editor.insert_paste_marker("a\nb\nc", 3)
    editor.text.should eq("X[paste #1 +3 lines]")

    editor.expand_markers.should be_true
    editor.text.should eq("Xa\nb\nc")
    editor.pasted?.should be_false
  end
end
