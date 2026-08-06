require "../spec_helper"
require "../../src/tui/input"

describe Hcode::TUI::Input do
  input = Hcode::TUI::Input.new

  it "parses a standalone ESC followed by DEL as Alt+Backspace" do
    key, consumed = input.parse_one([27_u8, 127_u8])
    consumed.should eq(2)
    key.should_not be_nil
    key = key.not_nil!
    key.key.should eq(Hcode::TUI::Key::Backspace)
    key.alt?.should be_true
  end

  it "parses a standalone ESC followed by BS as Alt+Backspace" do
    key, consumed = input.parse_one([27_u8, 8_u8])
    consumed.should eq(2)
    key.should_not be_nil
    key = key.not_nil!
    key.key.should eq(Hcode::TUI::Key::Backspace)
    key.alt?.should be_true
  end

  it "parses Alt+Enter (ESC + LF) as alt-flagged Enter" do
    key, consumed = input.parse_one([27_u8, 10_u8])
    consumed.should eq(2)
    key.should_not be_nil
    key = key.not_nil!
    key.key.should eq(Hcode::TUI::Key::Enter)
    key.alt?.should be_true
  end

  it "parses a lone DEL as plain Backspace" do
    key, consumed = input.parse_one([127_u8])
    consumed.should eq(1)
    key.should_not be_nil
    key = key.not_nil!
    key.key.should eq(Hcode::TUI::Key::Backspace)
    key.alt?.should be_false
  end

  it "parses a printable ASCII char as Char" do
    key, consumed = input.parse_one([97_u8]) # 'a'
    consumed.should eq(1)
    key.should_not be_nil
    key = key.not_nil!
    key.key.should eq(Hcode::TUI::Key::Char)
    key.char.should eq('a')
  end

  it "parses Alt+<printable> as alt-flagged Char" do
    key, consumed = input.parse_one([27_u8, 98_u8]) # ESC + 'b'
    consumed.should eq(2)
    key.should_not be_nil
    key = key.not_nil!
    key.key.should eq(Hcode::TUI::Key::Char)
    key.char.should eq('b')
    key.alt?.should be_true
  end
end
