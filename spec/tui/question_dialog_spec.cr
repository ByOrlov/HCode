require "../spec_helper"

private def build_question(text : String, options : Array(String), multi = false) : Hcode::Tools::QuestionItem
  Hcode::Tools::QuestionItem.new(
    text,
    options.map { |o| Hcode::Tools::QuestionOption.new(o) },
    multi_select: multi,
  )
end

private def key_event(key : Hcode::TUI::Key) : Hcode::TUI::KeyEvent
  Hcode::TUI::KeyEvent.new(key)
end

private def make_receiver
  # Buffered (capacity 1) so the callback's `send` does not rendezvous —
  # otherwise `send` would block inside `handle_input` waiting for a
  # `receive` that can only run after handle_input returns (deadlock).
  ch = Channel(Hash(String, String)?).new(1)
  handler = Proc(Hash(String, String), Nil).new do |answers|
    ch.send(answers)
  end
  {ch, handler}
end

private def expect_answers(ch) : Hash(String, String)
  received = ch.receive
  raise "expected non-nil answers" unless received
  received.as(Hash(String, String))
end

describe Hcode::TUI::QuestionDialog do
  it "dismisses (empty answers) on Esc" do
    dialog = Hcode::TUI::QuestionDialog.new(Hcode::TUI::Theme.dark)
    ch, handler = make_receiver
    dialog.show([build_question("Pick one", ["A", "B"])], handler)
    dialog.handle_input(key_event(Hcode::TUI::Key::Escape))
    answers = ch.receive
    answers.should eq({} of String => String)
    dialog.visible?.should be_false
  end

  it "records a single-select answer and auto-advances to submit" do
    dialog = Hcode::TUI::QuestionDialog.new(Hcode::TUI::Theme.dark)
    ch, handler = make_receiver
    dialog.show([build_question("Pick one", ["A", "B"])], handler)
    dialog.handle_input(key_event(Hcode::TUI::Key::Enter))
    dialog.render(80).any?(&.includes?("Review your answer")).should be_true
    dialog.handle_input(key_event(Hcode::TUI::Key::Enter))
    answers = expect_answers(ch)
    answers.should eq({"Pick one" => "A"})
  end

  it "toggles multiple options in multi-select mode" do
    dialog = Hcode::TUI::QuestionDialog.new(Hcode::TUI::Theme.dark)
    ch, handler = make_receiver
    dialog.show([build_question("Pick many", ["A", "B"], multi: true)], handler)
    # Enter on option 0 toggles it (multi-select).
    dialog.handle_input(key_event(Hcode::TUI::Key::Enter))
    dialog.handle_input(key_event(Hcode::TUI::Key::Down))
    dialog.handle_input(key_event(Hcode::TUI::Key::Enter))
    dialog.handle_input(key_event(Hcode::TUI::Key::Tab))
    dialog.handle_input(key_event(Hcode::TUI::Key::Enter))
    answers = expect_answers(ch)
    answers["Pick many"].split(", ").sort.should eq(["A", "B"])
  end

  it "renders question tabs with answered markers" do
    dialog = Hcode::TUI::QuestionDialog.new(Hcode::TUI::Theme.dark)
    handler = Proc(Hash(String, String), Nil).new { |_| }
    dialog.show([build_question("Q1", ["A", "B"]), build_question("Q2", ["X", "Y"])], handler)
    dialog.handle_input(key_event(Hcode::TUI::Key::Enter))
    lines = dialog.render(80).join("\n")
    lines.should contain("(✓) Q1")
  end
end
