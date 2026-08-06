require "../spec_helper"

module Hcode
  class SleepTool < Tools::Tool
    def name : String
      "Sleep"
    end

    def description : String
      "Sleeps for a configured duration and returns a fixed result."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "duration_ms": {"type": "integer"},
          "result": {"type": "string"}
        },
        "required": ["duration_ms", "result"]
      }))
    end

    def execute(input : JSON::Any) : Tools::ToolResult
      duration_ms = input["duration_ms"].as_i
      result = input["result"].to_s
      sleep duration_ms.milliseconds
      Tools::ToolResult.success(result)
    end
  end

  module ToolBatchSpecHelper
    def self.make_registry(tools : Array(Tools::Tool)) : Tools::Registry
      registry = Tools::Registry.new
      tools.each { |t| registry.register(t) }
      registry
    end

    def self.make_batch(tools : Array(Tools::Tool),
                        permission : Permission::Manager? = nil,
                        context : Context::Memory? = nil) : Loop::ToolBatch
      Loop::ToolBatch.new(
        registry: make_registry(tools),
        permission: permission || Permission::Manager.new(Permission::Mode::Yolo),
        dedup: Loop::DedupTracker.new,
        abort_controller: Loop::AbortController.new,
        context: context || Context::Memory.new,
      )
    end

    def self.tool_call(id : String, name : String, args : String = "{}") : LLM::ToolCall
      LLM::ToolCall.new(id, LLM::ToolCallFunction.new(name, args))
    end
  end
end

describe Hcode::Loop::ToolBatch do
  helper = Hcode::ToolBatchSpecHelper

  it "executes independent tool calls in parallel" do
    batch = helper.make_batch([Hcode::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":150,"result":"a"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":150,"result":"b"})),
    ]

    events = [] of Hcode::Loop::Event
    started = Time.monotonic
    results = batch.run(calls) { |e| events << e }
    elapsed = Time.monotonic - started

    results.size.should eq(2)
    results.map(&.tool_call_id).should eq(["call_1", "call_2"])
    # Parallel: two 150ms sleeps should finish in well under 300ms even with scheduler jitter.
    elapsed.total_milliseconds.should be < 275
  end

  it "preserves result order regardless of completion order" do
    batch = helper.make_batch([Hcode::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":200,"result":"slow-first"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"fast-second"})),
    ]

    results = batch.run(calls) { |_| }

    results.size.should eq(2)
    results[0].tool_call_id.should eq("call_1")
    results[1].tool_call_id.should eq("call_2")
    results[0].text.should contain("slow-first")
    results[1].text.should contain("fast-second")
  end

  it "emits tool_result events as results arrive" do
    batch = helper.make_batch([Hcode::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":150,"result":"a"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"b"})),
    ]

    result_events = [] of Hcode::Loop::Event
    batch.run(calls) do |e|
      result_events << e if e.type.tool_result?
    end

    result_events.size.should eq(2)
    # The faster tool should report first even though it is second in the batch.
    result_events[0].tool_call_id.should eq("call_2")
    result_events[1].tool_call_id.should eq("call_1")
  end

  it "returns an error for unknown tools without affecting others" do
    batch = helper.make_batch([Hcode::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "MissingTool"),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"ok"})),
    ]

    events = [] of Hcode::Loop::Event
    results = batch.run(calls) { |e| events << e }

    results.size.should eq(2)
    results[0].text.should contain("Unknown tool")
    results[1].text.should contain("ok")
  end

  it "deduplicates identical calls within the same step" do
    batch = helper.make_batch([Hcode::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":20,"result":"only-once"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"only-once"})),
    ]

    results = batch.run(calls) { |_| }

    results.size.should eq(2)
    results[0].text.should contain("only-once")
    results[1].text.should contain("Duplicate")
  end

  it "aborts running tool fibers" do
    batch = helper.make_batch([Hcode::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":5000,"result":"never"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"quick"})),
    ]

    abort = batch.@abort_controller
    spawn do
      sleep 50.milliseconds
      abort.abort("test cancel")
    end

    results = batch.run(calls) { |_| }

    # The quick tool should finish; the long one should be cancelled or time out.
    results.size.should eq(2)
    results[0].text.should match(/Cancelled|timed out|Execution failed/)
    results[1].text.should contain("quick")
  end

  it "appends tool results to context in input order" do
    context = Hcode::Context::Memory.new
    batch = helper.make_batch([Hcode::SleepTool.new], context: context)

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":200,"result":"slow"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"fast"})),
    ]

    batch.run(calls) { |_| }

    tool_messages = context.messages.select { |m| m.role == "tool" }
    tool_messages.size.should eq(2)
    tool_messages[0].tool_call_id.should eq("call_1")
    tool_messages[1].tool_call_id.should eq("call_2")
    tool_messages[0].text.should contain("slow")
    tool_messages[1].text.should contain("fast")
  end
end
