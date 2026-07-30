require "../spec_helper"
require "../../src/tui/usage_panel"

describe Hcode::TUI::UsagePanel do
  it "is hidden by default" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    panel.visible?.should be_false
  end

  it "shows and hides" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    panel.show
    panel.visible?.should be_true
    panel.hide
    panel.visible?.should be_false
  end

  it "renders provider, model, and token usage" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    panel.show
    lines = panel.render(80, "moonshot", "kimi-k2", 5000, 200000, 2.5, 12, 0)

    joined = lines.join('\n')
    joined.should contain("moonshot")
    joined.should contain("kimi-k2")
    joined.should contain("5000")
    joined.should contain("200000")
    joined.should contain("Context")
    joined.should contain("Messages")
  end

  it "handles Enter to close" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    closed = false
    cb = Proc(Nil).new { closed = true }
    panel.on_close = cb
    panel.show

    result = panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Enter))
    result.should be_true
    panel.visible?.should be_false
    closed.should be_true
  end

  it "handles Esc to close" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    panel.show

    panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Escape))
    panel.visible?.should be_false
  end

  it "handles q to close" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    panel.show

    panel.handle_input(Hcode::TUI::KeyEvent.char('q'))
    panel.visible?.should be_false
  end

  it "does not consume keys when hidden" do
    panel = Hcode::TUI::UsagePanel.new(Hcode::TUI::Theme.dark)
    panel.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Enter)).should be_false
  end
end
