require "../spec_helper"
require "../../src/loop/retry"

describe H2code::Loop::RetryPolicy do
  it "computes exponential backoff capped at max_delay" do
    policy = H2code::Loop::RetryPolicy.new(max_retries: 4, base_delay: 2, max_delay: 30)

    policy.delay_for(1).should eq(2)  # 2^1
    policy.delay_for(2).should eq(4)  # 2^2
    policy.delay_for(3).should eq(8)  # 2^3
    policy.delay_for(4).should eq(16) # 2^4
  end

  it "caps delay at max_delay" do
    policy = H2code::Loop::RetryPolicy.new(max_retries: 6, base_delay: 2, max_delay: 30)

    policy.delay_for(5).should eq(30) # 2^5=32, capped to 30
    policy.delay_for(6).should eq(30)
  end

  it "returns nil when retries are exhausted" do
    policy = H2code::Loop::RetryPolicy.new(max_retries: 3)

    policy.delay_for(3).should eq(8)
    policy.delay_for(4).should be_nil
  end

  it "considers ApiError retryable only when its flag is set" do
    policy = H2code::Loop::RetryPolicy.new

    retryable = H2code::LLM::ApiError.new(429, "rate limited", retryable: true)
    fatal = H2code::LLM::ApiError.new(401, "unauthorized", retryable: false)

    policy.retryable?(retryable).should be_true
    policy.retryable?(fatal).should be_false
  end

  it "treats generic network errors as retryable" do
    policy = H2code::Loop::RetryPolicy.new
    policy.retryable?(IO::Error.new("connection reset")).should be_true
  end

  it "treats stream stall timeouts as retryable" do
    policy = H2code::Loop::RetryPolicy.new
    policy.retryable?(H2code::LLM::StreamTimeoutError.new(60)).should be_true
  end

  it "never retries user cancellation" do
    policy = H2code::Loop::RetryPolicy.new
    policy.retryable?(H2code::Loop::UserCancellationError.new("cancelled")).should be_false
  end
end
