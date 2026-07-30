require "../spec_helper"
require "../support/mock_http_transport"

# Minimal concrete subclass so we can instantiate the abstract provider.
private class TestProvider < Hcode::LLM::OpenAIChatProvider
  def token : String
    "test-key"
  end

  def name : String
    "test"
  end
end

# Helper: build a valid SSE line for a text-content delta chunk.
private def sse_text_chunk(content : String, finish : String? = nil) : String
  JSON.build do |json|
    json.object do
      json.field "choices" do
        json.array do
          json.object do
            json.field "delta" do
              json.object { json.field "content", content }
            end
            json.field "finish_reason", finish if finish
          end
        end
      end
    end
  end
end

# Helper: build a final chunk carrying usage.
private def sse_usage_chunk : String
  JSON.build do |json|
    json.object do
      json.field "choices" { json.array { } }
      json.field "usage" do
        json.object do
          json.field "prompt_tokens", 10
          json.field "completion_tokens", 5
          json.field "total_tokens", 15
        end
      end
    end
  end
end

describe Hcode::LLM::OpenAIChatProvider do
  describe "with MockHttpTransport" do
    it "streams response chunks and aggregates text" do
      transport = Hcode::MockHttpTransport.new
      transport.mode = Hcode::MockHttpTransport::Mode::NormalStream
      transport.stream_lines = [
        sse_text_chunk("Hello"),
        sse_text_chunk(" world"),
        sse_text_chunk("", "end_turn"),
        sse_usage_chunk,
      ]

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      parts = [] of Hcode::LLM::MessagePart
      result = provider.chat([Hcode::LLM::Message.user("hi")], nil) { |p| parts << p }

      texts = parts.select(Hcode::LLM::TextPart).map(&.text).join
      texts.should eq("Hello world")
      result.text.should eq("Hello world")
      result.stop_reason.should eq("end_turn")
    end

    it "raises ApiError on non-200 status" do
      transport = Hcode::MockHttpTransport.new
      transport.mode = Hcode::MockHttpTransport::Mode::ErrorStatus
      transport.error_status = 429
      transport.error_body = %({"error":{"message":"rate limited"}})

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      expect_raises(Hcode::LLM::ApiError) do
        provider.chat([Hcode::LLM::Message.user("hi")], nil) { }
      end
    end

    it "surfaces network drop (IO::Error) from mid-stream as provider error" do
      transport = Hcode::MockHttpTransport.new
      transport.mode = Hcode::MockHttpTransport::Mode::DropMidStream
      transport.stream_lines = [sse_text_chunk("partial")]
      transport.stream_error = IO::Error.new("Broken pipe")

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      error = expect_raises(IO::Error) do
        provider.chat([Hcode::LLM::Message.user("hi")], nil) { }
      end
      (error.message || "").should contain("Broken pipe")
    end

    it "aborts an in-flight stream without unhandled spawn exceptions" do
      transport = Hcode::MockHttpTransport.new
      transport.mode = Hcode::MockHttpTransport::Mode::Blocking

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      abort_flag = ->{ true }

      expect_raises(Hcode::LLM::AbortedError) do
        provider.chat([Hcode::LLM::Message.user("hi")], nil, aborted?: abort_flag) { }
      end
    end

    it "uses transport for fetch_models (single-shot request)" do
      transport = Hcode::MockHttpTransport.new
      provider = TestProvider.new("m", "http://localhost", transport: transport)

      models = provider.fetch_models
      models.should eq([] of String)

      last = transport.last_uri.not_nil!
      last.to_s.should contain("/models")
      transport.last_headers.not_nil!["Authorization"].should eq("Bearer test-key")
    end
  end
end
