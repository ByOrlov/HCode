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
end
