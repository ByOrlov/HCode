require "../spec_helper"
require "../../src/tui/diff"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"

# Regression: the white (hardware terminal) cursor must stay in sync with the
# blue (rendered inverse-video) cursor in the editor box. When the editor
# expands and the user deletes words, the hardware cursor used to drift because
# `position_cursor` worked in absolute content coordinates while cursor movement
# is screen-relative. This finds the screen row of the rendered block cursor on
# the mock's screen grid and asserts the hardware cursor lands on the same row.
private def block_cursor_screen_row(mock : Hcode::TUI::TerminalMock) : Int32?
  # The rendered block cursor paints the cursor cell with a background colour
  # SGR (`\e[48;...m`). Find the screen row containing it.
  mock.screen.each_with_index do |line, idx|
    return idx if line.includes?("\e[48;")
  end
  nil
end

describe "Editor cursor sync (white vs blue)" do
  it "keeps hardware cursor on the block-cursor row after word deletions (moderate editor)" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: 24, cols: 80)
    editor = app.@editor

    5.times { |i| app.add_message("assistant", "log line number #{i} " + ("word " * 20)) }
    editor.set(("the quick brown fox " * 30))
    app.render_to(mock)

    15.times do
      ev = Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace)
      ev.alt = true
      editor.handle_input(ev)
      app.render_to(mock)
      blue = block_cursor_screen_row(mock)
      blue.should_not be_nil
      mock.cursor_row.should eq(blue), "hardware row #{mock.cursor_row} != block row #{blue}"
    end
  end

  it "keeps hardware cursor on the block-cursor row when editor overflows the viewport" do
    app = Hcode::TUI::App.new
    mock = Hcode::TUI::TerminalMock.new(rows: 24, cols: 80)
    editor = app.@editor

    3.times { |i| app.add_message("assistant", "log line number #{i} " + ("word " * 20)) }
    # Editor wraps into more rows than the viewport can show (overflow).
    editor.set(("the quick brown fox " * 60))
    app.render_to(mock)

    10.times do
      ev = Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace)
      ev.alt = true
      editor.handle_input(ev)
      app.render_to(mock)
      blue = block_cursor_screen_row(mock)
      next unless blue # cursor may be clipped; when visible it must match
      mock.cursor_row.should eq(blue), "hardware row #{mock.cursor_row} != block row #{blue}"
    end
  end
end
