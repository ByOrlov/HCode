require "../spec_helper"
require "../../src/acp/event_translator"

describe H2code::Acp::EventTranslator do
  describe ".wire_id" do
    it "builds turn_id:tool_call_id format" do
      H2code::Acp::EventTranslator.wire_id(3, "call_abc").should eq("3:call_abc")
    end
  end

  describe ".infer_tool_kind" do
    it "maps read tools" do
      H2code::Acp::EventTranslator.infer_tool_kind("Read").should eq("read")
      H2code::Acp::EventTranslator.infer_tool_kind("Glob").should eq("read")
      H2code::Acp::EventTranslator.infer_tool_kind("Grep").should eq("read")
    end

    it "maps edit tools" do
      H2code::Acp::EventTranslator.infer_tool_kind("Write").should eq("edit")
      H2code::Acp::EventTranslator.infer_tool_kind("Edit").should eq("edit")
    end

    it "maps execute tools" do
      H2code::Acp::EventTranslator.infer_tool_kind("Bash").should eq("execute")
    end

    it "maps fetch tools" do
      H2code::Acp::EventTranslator.infer_tool_kind("FetchURL").should eq("fetch")
      H2code::Acp::EventTranslator.infer_tool_kind("WebSearch").should eq("fetch")
    end

    it "defaults to other" do
      H2code::Acp::EventTranslator.infer_tool_kind("TodoList").should eq("other")
      H2code::Acp::EventTranslator.infer_tool_kind("UnknownTool").should eq("other")
    end
  end

  describe ".stop_reason" do
    it "maps cancelled to cancelled" do
      H2code::Acp::EventTranslator.stop_reason(true).should eq("cancelled")
    end

    it "maps normal completion to end_turn" do
      H2code::Acp::EventTranslator.stop_reason(false).should eq("end_turn")
    end
  end

  describe ".assistant_delta" do
    it "produces agent_message_chunk notification" do
      result = H2code::Acp::EventTranslator.assistant_delta("sess1", "hello")
      update = result["update"]
      update["kind"].to_s.should eq("agent_message_chunk")
      update["content"].as_a[0]["text"].to_s.should eq("hello")
      result["sessionId"].to_s.should eq("sess1")
    end
  end

  describe ".thinking_delta" do
    it "produces agent_thought_chunk notification" do
      result = H2code::Acp::EventTranslator.thinking_delta("sess1", "reasoning")
      update = result["update"]
      update["kind"].to_s.should eq("agent_thought_chunk")
      update["content"].as_a[0]["text"].to_s.should eq("reasoning")
    end
  end

  describe ".tool_call_start" do
    it "produces tool_call CREATE notification" do
      result = H2code::Acp::EventTranslator.tool_call_start("sess1", 1, "call_1", "Bash", %({"command":"ls"}))
      update = result["update"]
      update["kind"].to_s.should eq("tool_call")
      update["toolCallId"].to_s.should eq("1:call_1")
      update["title"].to_s.should eq("Bash")
      update["toolKind"].to_s.should eq("execute")
      update["status"].to_s.should eq("in_progress")
    end

    it "produces empty content when args is empty" do
      result = H2code::Acp::EventTranslator.tool_call_start("sess1", 1, "call_1", "Read", "")
      update = result["update"]
      update["content"].as_a.should be_empty
    end
  end

  describe ".tool_result" do
    it "produces completed status for success" do
      result = H2code::Acp::EventTranslator.tool_result("sess1", 1, "call_1", "output", false)
      update = result["update"]
      update["kind"].to_s.should eq("tool_call_update")
      update["status"].to_s.should eq("completed")
    end

    it "produces failed status for error" do
      result = H2code::Acp::EventTranslator.tool_result("sess1", 1, "call_1", "error msg", true)
      update = result["update"]
      update["status"].to_s.should eq("failed")
    end

    it "includes rawOutput when provided" do
      result = H2code::Acp::EventTranslator.tool_result("sess1", 1, "call_1", "out", false, "raw")
      update = result["update"]
      update["rawOutput"].to_s.should eq("raw")
    end
  end
end
