require "../spec_helper"

describe H2code::Context::Budget do
  it "returns content as-is when under limit" do
    content = "x" * 100
    result, truncated = H2code::Context::Budget.budget(H2code::Tools::Names::BASH, "call_1", content)
    truncated.should be_false
    result.should eq(content)
  end

  it "truncates content when over limit" do
    content = "x" * (H2code::Context::Budget::MAX_RESULT_CHARS + 100)
    result, truncated = H2code::Context::Budget.budget(H2code::Tools::Names::BASH, "call_1", content)
    truncated.should be_true
    result.should contain("Output truncated")
    result.should contain("Full output saved to")
  end
end
