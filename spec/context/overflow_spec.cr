require "../spec_helper"

describe H2code::Context::Overflow do
  describe "::Recovery" do
    it "starts in the normal projection" do
      r = H2code::Context::Overflow::Recovery.new
      r.projection.normal?.should be_true
      r.media_degraded_used?.should be_false
      r.compaction_used?.should be_false
    end

    it "reset returns to the initial state" do
      r = H2code::Context::Overflow::Recovery.new
      r.compaction_used = true
      r.projection = H2code::Context::Overflow::Projection::MediaStripped
      r.reset
      r.compaction_used?.should be_false
      r.projection.normal?.should be_true
    end
  end

  describe ".request_too_large?" do
    it "true for a 413 ApiError" do
      err = H2code::LLM::ApiError.new(413, "too large", false)
      H2code::Context::Overflow.request_too_large?(err).should be_true
    end

    it "false for other status codes" do
      err = H2code::LLM::ApiError.new(429, "rate limited", true)
      H2code::Context::Overflow.request_too_large?(err).should be_false
    end

    it "false for generic exceptions" do
      H2code::Context::Overflow.request_too_large?(Exception.new("nope")).should be_false
    end
  end

  describe ".token_overflow?" do
    it "mirrors Memory#near_limit?" do
      mem = H2code::Context::Memory.new
      mem.max_context_tokens = 10
      mem.add_user("a reasonably long message to cross the 90% threshold")
      H2code::Context::Overflow.token_overflow?(mem).should be_true
    end
  end

  describe ".recover_from_413" do
    it "without media goes straight to compact, then fail" do
      r = H2code::Context::Overflow::Recovery.new
      H2code::Context::Overflow.recover_from_413(r, has_media: false).should eq(H2code::Context::Overflow::Action::Compact)
      r.compaction_used?.should be_true
      # Second call cannot compact again.
      H2code::Context::Overflow.recover_from_413(r, has_media: false).should eq(H2code::Context::Overflow::Action::Fail)
    end

    it "with media walks degrade -> strip -> compact" do
      r = H2code::Context::Overflow::Recovery.new
      H2code::Context::Overflow.recover_from_413(r, has_media: true).should eq(H2code::Context::Overflow::Action::RetryDegraded)
      H2code::Context::Overflow.recover_from_413(r, has_media: true).should eq(H2code::Context::Overflow::Action::RetryStripped)
      H2code::Context::Overflow.recover_from_413(r, has_media: true).should eq(H2code::Context::Overflow::Action::Compact)
      H2code::Context::Overflow.recover_from_413(r, has_media: true).should eq(H2code::Context::Overflow::Action::Fail)
    end
  end

  describe ".parse_context_limit" do
    it "extracts a numeric cap from the error body" do
      err = H2code::LLM::ApiError.new(413, "This model's maximum context length is 131072 tokens.", false)
      H2code::Context::Overflow.parse_context_limit(err).should eq(131072)
    end

    it "extracts a max_tokens cap" do
      err = H2code::LLM::ApiError.new(413, "max_tokens: 200000 exceeded", false)
      H2code::Context::Overflow.parse_context_limit(err).should eq(200000)
    end

    it "returns nil when no cap is mentioned" do
      err = H2code::LLM::ApiError.new(413, "request too large", false)
      H2code::Context::Overflow.parse_context_limit(err).should be_nil
    end
  end

  describe ".apply_learned_limit!" do
    it "lowers the memory's cap to the learned limit" do
      mem = H2code::Context::Memory.new
      mem.max_context_tokens = 200000
      r = H2code::Context::Overflow::Recovery.new
      err = H2code::LLM::ApiError.new(413, "maximum context length is 131072 tokens", false)
      H2code::Context::Overflow.apply_learned_limit!(mem, r, err)
      mem.max_context_tokens.should eq(131072)
      r.learned_context_limit.should eq(131072)
    end

    it "does not raise the cap above the configured default" do
      mem = H2code::Context::Memory.new
      mem.max_context_tokens = 131072
      r = H2code::Context::Overflow::Recovery.new
      err = H2code::LLM::ApiError.new(413, "maximum context length is 999999 tokens", false)
      H2code::Context::Overflow.apply_learned_limit!(mem, r, err)
      mem.max_context_tokens.should eq(131072)
    end
  end
end
