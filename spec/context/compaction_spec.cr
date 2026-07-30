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

  it "reports token reduction when tokens decrease" do
    memory = Hcode::Context::Memory.new
    memory.add_user("a somewhat longer message here")
    memory.add_assistant("a reply that is also reasonably long")

    provider = make_summary_provider("Short summary.")
    compactor = Hcode::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.tokens_after.should be <= result.tokens_before
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
           &block : Hcode::LLM::MessagePart ->) : Hcode::LLM::StepResult
    raise "provider down"
  end
end
