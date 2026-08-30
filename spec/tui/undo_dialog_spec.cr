require "../spec_helper"

private def make_choice(count : Int32, input : String, label : String)
  H2code::TUI::UndoDialog::Choice.new("c#{count}", count, input, label)
end

private def key_event(key : H2code::TUI::Key) : H2code::TUI::KeyEvent
  H2code::TUI::KeyEvent.new(key)
end

private def noop_select
  Proc(H2code::TUI::UndoDialog::Choice, Nil).new { |_| }
end

describe H2code::TUI::UndoDialog do
  it "opens hidden and becomes visible after show" do
    dialog = H2code::TUI::UndoDialog.new(H2code::TUI::Theme.dark)
    dialog.visible?.should be_false
    dialog.show([make_choice(1, "hi", "Q1")], noop_select)
    dialog.visible?.should be_true
  end

  it "selects the current choice on Enter and invokes callback" do
    dialog = H2code::TUI::UndoDialog.new(H2code::TUI::Theme.dark)
    selected = [] of Int32
    handler = Proc(H2code::TUI::UndoDialog::Choice, Nil).new do |c|
      selected << c.count
    end
    dialog.show([make_choice(1, "a", "L1"), make_choice(3, "b", "L2")], handler)
    dialog.handle_input(key_event(H2code::TUI::Key::Enter))
    selected.should eq([3])
    dialog.visible?.should be_false
  end

  it "navigates up/down with arrow keys" do
    dialog = H2code::TUI::UndoDialog.new(H2code::TUI::Theme.dark)
    dialog.show([
      make_choice(1, "a", "L1"),
      make_choice(2, "b", "L2"),
      make_choice(3, "c", "L3"),
    ], noop_select)
    dialog.selected.should eq(2)
    dialog.handle_input(key_event(H2code::TUI::Key::Up))
    dialog.selected.should eq(1)
    dialog.handle_input(key_event(H2code::TUI::Key::Up))
    dialog.selected.should eq(0)
    dialog.handle_input(key_event(H2code::TUI::Key::Up))
    dialog.selected.should eq(2)
    dialog.handle_input(key_event(H2code::TUI::Key::Down))
    dialog.selected.should eq(0)
  end

  it "cancels on Esc and hides without selecting" do
    dialog = H2code::TUI::UndoDialog.new(H2code::TUI::Theme.dark)
    cancelled = [] of Bool
    cancel_cb = Proc(Nil).new { cancelled << true }
    dialog.show([make_choice(1, "a", "L1")], noop_select, cancel_cb)
    dialog.handle_input(key_event(H2code::TUI::Key::Escape))
    cancelled.should eq([true])
    dialog.visible?.should be_false
  end

  it "renders empty state when no choices" do
    dialog = H2code::TUI::UndoDialog.new(H2code::TUI::Theme.dark)
    empty_arr = [] of H2code::TUI::UndoDialog::Choice
    dialog.show(empty_arr, noop_select)
    lines = dialog.render(60).join("\n")
    lines.should contain("No messages")
  end

  it "renders the header and choices" do
    dialog = H2code::TUI::UndoDialog.new(H2code::TUI::Theme.dark)
    dialog.show([make_choice(1, "hi", "Q1: hi")], noop_select)
    lines = dialog.render(60).join("\n")
    lines.should contain("Select messages to undo")
    lines.should contain("Q1: hi")
  end
end
