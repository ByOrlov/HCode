require "../spec_helper"
require "../../src/context/compaction"

private def make_summary_provider(text : String)
  step = Hcode::LLM::MockStep.new(
    parts: [Hcode::LLM::TextPart.new(text)] of Hcode::LLM::MessagePart,
    stop_reason: "end_turn",
    text: text,
  )
  Hcode::LLM::MockProvider.new([step])
end

# A provider that records every request it receives and replays a scripted
# list of outcomes: either an exception to raise or a summary text to return.
private class ScriptedProvider < Hcode::LLM::Provider
  getter requests : Array(Array(Hcode::LLM::Message)) = [] of Array(Hcode::LLM::Message)
  @outcomes : Array(Exception | String)

  def initialize(outcomes : Array(Exception | String))
    @outcomes = outcomes.map { |o| o.as(Exception | String) }
  end

  def name : String
    "scripted"
  end

  def model_name : String
    "scripted"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(Hcode::LLM::Message), tools : Array(Hcode::LLM::ToolDefinition)?,
           system_prompt : String? = nil,
           aborted? : -> Bool = -> { false },
           &_block : Hcode::LLM::MessagePart ->) : Hcode::LLM::StepResult
    @requests << messages
    outcome = @outcomes.shift
    raise outcome.as(Exception) if outcome.is_a?(Exception)
    text = outcome.as(String)
    Hcode::LLM::StepResult.new(
      stop_reason: "end_turn",
      text: text,
      thinking: "",
      tool_calls: [] of Hcode::LLM::ToolCall,
      usage: Hcode::LLM::Usage.new,
    )
  end
end

private def zai_overflow_error : Hcode::LLM::ApiError
  Hcode::LLM::ApiError.new(400,
    "Chat API error 400: The messages parameter is illegal. Please check the documentation.",
    retryable: false)
end

describe Hcode::Context::Compaction do
  it "summarizes and applies the compaction" do
    memory = Hcode::Context::Memory.new
    memory.add_user("first message")
    memory.add_assistant("first reply")
    memory.add_user("second message")
    memory.add_assistant("second reply")

    provider = make_summary_provider("Summary of the conversation.")
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 2)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Summary of the conversation.")
    # Kept the last 2 messages + the summary message itself.
    memory.history.size.should eq(3)
    result.messages_after.should eq(2)
  end

  it "sends the history as a message list plus a trailing instruction, not one blob" do
    memory = Hcode::Context::Memory.new
    memory.add_user("first message")
    memory.add_assistant("first reply")

    provider = ScriptedProvider.new(["Summary."])
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 1)

    compactor.compact { }

    request = provider.requests.first
    request.map(&.role).should eq(["user", "assistant", "user"])
    request[0].text.should eq("first message")
    request[1].text.should eq("first reply")
    request.last.text.should contain("handoff note")
  end

  it "excludes injection-origin messages from the summarizer input" do
    memory = Hcode::Context::Memory.new
    memory.add_user("real question")
    memory.add_injection("[step reminder]")
    memory.add_assistant("answer")

    provider = ScriptedProvider.new(["Summary."])
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 1)

    compactor.compact { }

    request = provider.requests.first
    request.map(&.role).should eq(["user", "assistant", "user"])
    request.none?(&.text.includes?("step reminder")).should be_true
  end

  it "synthesizes missing tool results and drops orphan tool results" do
    projected = Hcode::Context::Compaction.project([
      Hcode::LLM::Message.user("run tools"),
      Hcode::LLM::Message.assistant("", tool_calls: [
        Hcode::LLM::ToolCall.new("call_1", Hcode::LLM::ToolCallFunction.new("bash", "{}")),
        Hcode::LLM::ToolCall.new("call_2", Hcode::LLM::ToolCallFunction.new("read", "{}")),
      ]),
      Hcode::LLM::Message.tool("out 1", "call_1"),
      # Orphan: no assistant message ever made this call.
      Hcode::LLM::Message.tool("stray", "call_unknown"),
    ])

    roles = projected.map(&.role)
    # user, assistant, then both tool results (the synthesized one for the
    # unanswered call_2 lands directly after the assistant, before the real
    # call_1 result); the orphan is dropped.
    roles.should eq(["user", "assistant", "tool", "tool"])
    tool_ids = projected.select(&.role.==("tool")).compact_map(&.tool_call_id).sort!
    tool_ids.should eq(["call_1", "call_2"])
    synthesized = projected.find!(&.text.includes?("unavailable"))
    synthesized.tool_call_id.should eq("call_2")
    projected.none?(&.text.includes?("stray")).should be_true
  end

  it "shrinks the history and retries when the summarizer request overflows" do
    memory = Hcode::Context::Memory.new
    20.times do |i|
      memory.add_user("question number #{i} with some padding text to give it tokens")
      memory.add_assistant("answer number #{i} with some padding text to give it tokens")
    end
    # Small window so the request estimate crosses the recovery ratio gate.
    memory.max_context_tokens = 1000

    provider = ScriptedProvider.new([zai_overflow_error, zai_overflow_error, "Shrunk summary."])
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 2)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Shrunk summary.")
    result.dropped_count.should be > 0
    provider.requests.size.should eq(3)
    # Each overflow retry sent a strictly smaller prefix of the history.
    provider.requests[1].size.should be < provider.requests[0].size
    provider.requests[2].size.should be < provider.requests[1].size
    # Shrunk requests still end with the instruction and never start on a tool result.
    provider.requests.each do |request|
      request.last.text.should contain("handoff note")
      request.first.role.should_not eq("tool")
    end
  end

  it "does not treat a small-request 400 as overflow" do
    memory = Hcode::Context::Memory.new
    memory.add_user("hello")
    memory.max_context_tokens = 1_000_000

    provider = ScriptedProvider.new([zai_overflow_error])
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.failed?.should be_true
    provider.requests.size.should eq(1)
    memory.history.size.should eq(2) # full history retained + failure summary
  end

  it "retains full history on provider failure" do
    memory = Hcode::Context::Memory.new
    memory.add_user("hello")

    failing = FailingProvider.new
    compactor = Hcode::Context::Compaction.new(failing, memory, kept_count: 2)

    result = compactor.compact { }

    result.failed?.should be_true
    # Full history retained (1) + the failure summary message = 2.
    memory.history.size.should eq(2)
  end

  it "drops the oldest message and retries on an empty summary" do
    memory = Hcode::Context::Memory.new
    memory.add_user("first")
    memory.add_assistant("first reply")
    memory.add_user("second")

    provider = ScriptedProvider.new(["", "Retry summary."])
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Retry summary.")
    result.dropped_count.should eq(1)
    provider.requests[1].size.should be < provider.requests[0].size
  end

  it "reports token reduction when tokens decrease" do
    memory = Hcode::Context::Memory.new
    memory.add_user("a somewhat longer message here")
    memory.add_assistant("a reply that is also reasonably long")

    provider = make_summary_provider("Short summary.")
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.tokens_after.should be <= result.tokens_before
  end

  describe ".take_recent_within_token_budget" do
    it "keeps the most recent messages that fit and never returns a tool-first slice" do
      cms = [
        Hcode::Context::ContextMessage.new(Hcode::LLM::Message.user("0123456789" * 10)),
        Hcode::Context::ContextMessage.new(Hcode::LLM::Message.tool("out", "c1")),
        Hcode::Context::ContextMessage.new(Hcode::LLM::Message.user("short")),
      ]
      kept = Hcode::Context::Compaction.take_recent_within_token_budget(cms, 10)
      kept.size.should eq(1)
      kept.first.message.text.should eq("short")
    end
  end

  describe ".overflow_error?" do
    it "classifies 413 and Z.AI-style oversized-input 400s" do
      overflow_413 = Hcode::LLM::ApiError.new(413, "Chat API error 413: too large")
      Hcode::Context::Compaction.overflow_error?(overflow_413, 600, 1000).should be_true
      # Estimate below the recovery ratio: shrinking cannot be the fix.
      Hcode::Context::Compaction.overflow_error?(overflow_413, 400, 1000).should be_false
      # 400 with a matching body and a near-full request.
      Hcode::Context::Compaction.overflow_error?(zai_overflow_error, 900, 1000).should be_true
      # 400 that does not blame the input (e.g. invalid model).
      other_400 = Hcode::LLM::ApiError.new(400, "Chat API error 400: invalid model id", retryable: false)
      Hcode::Context::Compaction.overflow_error?(other_400, 900, 1000).should be_false
    end
  end
end

private class FailingProvider < Hcode::LLM::Provider
  def name : String
    "failing"
  end

  def model_name : String
    "failing"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(Hcode::LLM::Message), tools : Array(Hcode::LLM::ToolDefinition)?,
           system_prompt : String? = nil,
           aborted? : -> Bool = -> { false },
           &_block : Hcode::LLM::MessagePart ->) : Hcode::LLM::StepResult
    raise "provider down"
  end
end
