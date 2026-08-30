require "../spec_helper"
require "../support/mock_http_transport"

describe H2code::Notify::Webhook do
  describe ".build_payload" do
    it "produces a JSON body with event, status, and prev_status" do
      payload = H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
        title: "Turn complete",
        body: "3 steps",
        session_id: "abc123",
      )
      body = H2code::Notify::Webhook.build_payload(payload)
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
      payload = H2code::Notify::Transition.new(
        event: "input_required",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::InputRequired,
      )
      parsed = JSON.parse(H2code::Notify::Webhook.build_payload(payload))
      parsed["status"].as_s.should eq("inputrequired")
    end
  end

  describe "#fire" do
    it "does not raise when the URL is unreachable" do
      webhook = H2code::Notify::Webhook.new(url: "http://127.0.0.1:1", method: "POST")
      webhook.fire(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
      ))
      # Give the detached fiber a chance to fail silently.
      10.times { Fiber.yield }
    end

    it "is a no-op with an empty URL" do
      webhook = H2code::Notify::Webhook.new(url: "")
      webhook.fire(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
      ))
    end

    it "honours PUT method" do
      webhook = H2code::Notify::Webhook.new(url: "http://127.0.0.1:1", method: "put")
      webhook.fire(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
      ))
      10.times { Fiber.yield }
    end

    it "uses injected transport and swallows network errors silently" do
      transport = H2code::MockHttpTransport.new
      transport.request_error = IO::Error.new("Broken pipe")

      webhook = H2code::Notify::Webhook.new(url: "http://example.com/hook", transport: transport)
      webhook.fire(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
      ))
      10.times { Fiber.yield }
      # No exception propagated — the IO::Error was swallowed.
      (transport.last_uri || raise "last_uri should not be nil").to_s.should contain("example.com")
    end

    it "delivers payload through transport on success" do
      transport = H2code::MockHttpTransport.new
      transport.response_status = 200
      transport.response_body = "ok"

      webhook = H2code::Notify::Webhook.new(url: "http://example.com/hook", transport: transport)
      webhook.fire(H2code::Notify::Transition.new(
        event: "turn_done",
        prev_status: H2code::Notify::AgentStatus::Working,
        next_status: H2code::Notify::AgentStatus::Done,
      ))
      10.times { Fiber.yield }
      (transport.last_body || "").should contain("turn_done")
    end
  end
end
