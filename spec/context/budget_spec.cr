require "../spec_helper"

describe Hcode::Context::Budget do
  it "returns content as-is when under limit" do
    content = "x" * 100
    result, truncated = Hcode::Context::Budget.budget("Bash", "call_1", content)
    truncated.should be_false
    result.should eq(content)
  end

  it "truncates content when over limit" do
    content = "x" * (Hcode::Context::Budget::MAX_RESULT_CHARS + 100)
    result, truncated = Hcode::Context::Budget.budget("Bash", "call_1", content)
    truncated.should be_true
    result.should contain("Output truncated")
    result.should contain("Full output saved to")
  end
end
