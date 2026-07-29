require "../spec_helper"

describe Hcode::Notify::Webhook do
  describe ".build_payload" do
    it "produces a JSON body with event, status, and prev_status" do
      payload = Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
        title: "Turn complete",
        body: "3 steps",
        session_id: "abc123",
      )
      body = Hcode::Notify::Webhook.build_payload(payload)
      parsed = JSON.parse(body)
      parsed["event"].as_s.should eq("turn_done")
      parsed["status"].as_s.should eq("done")
      parsed["prev_status"].as_s.should eq("working")
      parsed["title"].as_s.should eq("Turn complete")
      parsed["body"].as_s.should eq("3 steps")
      parsed["session_id"].as_s.should eq("abc123")
      parsed["timestamp"].as_s.size.should be > 0
    end

    it "lowercases status names" do
      payload = Hcode::Notify::Transition.new(
        event: "input_required",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::InputRequired,
      )
      parsed = JSON.parse(Hcode::Notify::Webhook.build_payload(payload))
      parsed["status"].as_s.should eq("inputrequired")
    end
  end

  describe "#fire" do
    it "does not raise when the URL is unreachable" do
      webhook = Hcode::Notify::Webhook.new(url: "http://127.0.0.1:1", method: "POST")
      webhook.fire(Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
      ))
      # Give the detached fiber a chance to fail silently.
      10.times { Fiber.yield }
    end

    it "is a no-op with an empty URL" do
      webhook = Hcode::Notify::Webhook.new(url: "")
      webhook.fire(Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
      ))
    end

    it "honours PUT method" do
      webhook = Hcode::Notify::Webhook.new(url: "http://127.0.0.1:1", method: "put")
      webhook.fire(Hcode::Notify::Transition.new(
        event: "turn_done",
        prev_status: Hcode::Notify::AgentStatus::Working,
        next_status: Hcode::Notify::AgentStatus::Done,
      ))
      10.times { Fiber.yield }
    end
  end
end
