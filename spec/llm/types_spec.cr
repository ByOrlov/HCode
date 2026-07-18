require "../spec_helper"

describe Hcode::LLM::Message do
  describe ".user" do
    it "creates a user message" do
      msg = Hcode::LLM::Message.user("hello")
      msg.role.should eq("user")
      msg.content.should eq("hello")
      msg.tool_calls.should be_nil
      msg.tool_call_id.should be_nil
    end
  end

  describe ".assistant" do
    it "creates an assistant message with text only" do
      msg = Hcode::LLM::Message.assistant("hi there")
      msg.role.should eq("assistant")
      msg.content.should eq("hi there")
      msg.tool_calls.should be_nil
    end

    it "creates an assistant message with tool_calls" do
      tc = Hcode::LLM::ToolCall.new("call_1", Hcode::LLM::ToolCallFunction.new("Bash", "{\"command\":\"ls\"}"))
      msg = Hcode::LLM::Message.assistant("", [tc])
      msg.role.should eq("assistant")
      msg.tool_calls.should_not be_nil
      msg.tool_calls.not_nil!.size.should eq(1)
      msg.tool_calls.not_nil![0].name.should eq("Bash")
    end
  end

  describe ".tool" do
    it "creates a tool result message" do
      msg = Hcode::LLM::Message.tool("result text", "call_1")
      msg.role.should eq("tool")
      msg.content.should eq("result text")
      msg.tool_call_id.should eq("call_1")
    end
  end

  describe "JSON serialization" do
    it "omits nil fields" do
      msg = Hcode::LLM::Message.user("test")
      json = JSON.parse(msg.to_json)
      json["role"].should eq("user")
      json["content"].should eq("test")
      json.as_h.has_key?("tool_calls").should be_false
      json.as_h.has_key?("tool_call_id").should be_false
    end

    it "includes tool_calls when present" do
      tc = Hcode::LLM::ToolCall.new("call_1", Hcode::LLM::ToolCallFunction.new("Bash", "{}"))
      msg = Hcode::LLM::Message.assistant(nil, [tc])
      json = JSON.parse(msg.to_json)
      json["tool_calls"].as_a.size.should eq(1)
    end
  end
end

describe Hcode::LLM::Usage do
  it "adds two usages" do
    u1 = Hcode::LLM::Usage.new(prompt_tokens: 100, completion_tokens: 50, total_tokens: 150)
    u2 = Hcode::LLM::Usage.new(prompt_tokens: 200, completion_tokens: 100, total_tokens: 300)
    combined = u1 + u2
    combined.prompt_tokens.should eq(300)
    combined.completion_tokens.should eq(150)
    combined.total_tokens.should eq(450)
  end
end

describe Hcode::LLM::StreamChunk do
  it "parses usage from the top-level field" do
    chunk = Hcode::LLM::StreamChunk.from_json(%({"usage":{"prompt_tokens":42,"completion_tokens":7,"total_tokens":49}}))
    u = chunk.usage.not_nil!
    u.prompt_tokens.should eq(42)
    u.completion_tokens.should eq(7)
  end

  it "parses Moonshot-proprietary usage from choices[0].usage" do
    chunk = Hcode::LLM::StreamChunk.from_json(%({"choices":[{"index":0,"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150}}]}))
    chunk.usage.should be_nil
    choice_usage = chunk.choices.first.usage.not_nil!
    choice_usage.prompt_tokens.should eq(120)
    choice_usage.completion_tokens.should eq(30)
  end
end

describe Hcode::LLM::ChatRequest do
  it "emits only the base fields when nothing extra is configured" do
    req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")])
    json = JSON.parse(req.to_json)
    json["model"].should eq("m")
    json["stream"].should eq(true)
    json.as_h.has_key?("prompt_cache_key").should be_false
    json.as_h.has_key?("max_completion_tokens").should be_false
    json.as_h.has_key?("thinking").should be_false
  end

  it "includes prompt_cache_key and stream_options when streaming" do
    req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")], stream: true)
    req.prompt_cache_key = "sess-123"
    json = JSON.parse(req.to_json)
    json["prompt_cache_key"].should eq("sess-123")
    json["stream_options"]["include_usage"].should be_true
  end

  it "prefers max_completion_tokens over the legacy max_tokens alias" do
    req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")], max_tokens: 4096)
    req.max_completion_tokens = 1024
    json = JSON.parse(req.to_json)
    json["max_completion_tokens"].should eq(1024)
    json.as_h.has_key?("max_tokens").should be_false
  end

  it "falls back to max_tokens when max_completion_tokens is unset" do
    req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")], max_tokens: 4096)
    json = JSON.parse(req.to_json)
    json["max_tokens"].should eq(4096)
  end

  describe "thinking wire dialects" do
    it "Moonshot dialect emits a thinking object without effort for boolean-only models" do
      req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")])
      req.thinking = Hcode::LLM::ThinkingConfig.new("enabled")
      json = JSON.parse(req.to_json)
      json["thinking"]["type"].should eq("enabled")
      json["thinking"].as_h.has_key?("effort").should be_false
    end

    it "reasoning_effort dialect emits a top-level string" do
      req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")])
      req.reasoning_effort = "medium"
      json = JSON.parse(req.to_json)
      json["reasoning_effort"].should eq("medium")
      json.as_h.has_key?("thinking").should be_false
    end
  end

  it "includes parallel_tool_calls when set" do
    tool = Hcode::LLM::ToolDefinition.new(Hcode::LLM::ToolFunction.new("Read", "reads", JSON.parse("{}")))
    req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")], tools: [tool])
    req.parallel_tool_calls = true
    json = JSON.parse(req.to_json)
    json["parallel_tool_calls"].should be_true
  end

  it "omits parallel_tool_calls when unset" do
    req = Hcode::LLM::ChatRequest.new("m", [Hcode::LLM::Message.user("hi")])
    json = JSON.parse(req.to_json)
    json.as_h.has_key?("parallel_tool_calls").should be_false
  end
end

describe Hcode::LLM::ApiError do
  describe ".retryable_status?" do
    it "treats rate-limit and request-timeout as retryable" do
      Hcode::LLM::ApiError.retryable_status?(408).should be_true
      Hcode::LLM::ApiError.retryable_status?(429).should be_true
    end

    it "treats 5xx server errors as retryable" do
      Hcode::LLM::ApiError.retryable_status?(500).should be_true
      Hcode::LLM::ApiError.retryable_status?(502).should be_true
      Hcode::LLM::ApiError.retryable_status?(503).should be_true
      Hcode::LLM::ApiError.retryable_status?(504).should be_true
    end

    it "treats auth/quota/not-found/bad-request as non-retryable" do
      {400, 401, 403, 404, 422}.each do |code|
        Hcode::LLM::ApiError.retryable_status?(code).should be_false
      end
    end
  end

  it "carries status code and the computed retryable flag" do
    err = Hcode::LLM::ApiError.new(403, "quota exceeded", retryable: false)
    err.status_code.should eq(403)
    err.retryable?.should be_false
    err.message.not_nil!.should contain("quota exceeded")
  end
end

describe Hcode::LLM::Provider do
  it "is the base class of MoonshotProvider" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.is_a?(Hcode::LLM::Provider).should be_true
  end
end

describe Hcode::LLM::MoonshotProvider do
  it "identifies itself as the moonshot backend" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.name.should eq("moonshot")
  end

  it "exposes the upstream model name" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.model_name.should eq("hcode-for-coding")
  end

  it "shares the OpenAI Chat Completions transport" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.is_a?(Hcode::LLM::OpenAIChatProvider).should be_true
  end
end

describe Hcode::LLM::ZaiProvider do
  it "is a Provider sharing the OpenAI Chat Completions transport" do
    provider = Hcode::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.is_a?(Hcode::LLM::Provider).should be_true
    provider.is_a?(Hcode::LLM::OpenAIChatProvider).should be_true
  end

  it "identifies itself as the zai backend" do
    provider = Hcode::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.name.should eq("zai")
  end

  it "defaults to the GLM coding model and the z.ai paas endpoint" do
    provider = Hcode::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.model_name.should eq("glm-4.6")
    provider.endpoint.should eq("https://api.z.ai/api/paas/v4")
  end

  it "authenticates with the plain API key (no OAuth)" do
    provider = Hcode::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.token.should eq("sk-test")
  end

  it "honours an explicit model and endpoint override" do
    provider = Hcode::LLM::ZaiProvider.new(model: "glm-4.7", endpoint: "https://custom.example/v4", api_key: "k")
    provider.model_name.should eq("glm-4.7")
    provider.endpoint.should eq("https://custom.example/v4")
  end
end

describe Hcode::LLM::MockProvider do
  it "is a Provider that needs no key or network" do
    provider = Hcode::LLM::MockProvider.new
    provider.is_a?(Hcode::LLM::Provider).should be_true
    provider.name.should eq("mock")
    provider.model_name.should eq("mock")
  end

  it "replays the script step by step and terminates" do
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::ToolCallPart.new("c1", "Bash", %({"command":"echo hi"}))] of Hcode::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      Hcode::LLM::MockStep.new(
        parts: [Hcode::LLM::TextPart.new("done")] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "done",
      ),
    ])

    first = provider.chat([] of Hcode::LLM::Message, nil) { }
    first.tool_use?.should be_true
    first.tool_calls.size.should eq(1)

    second = provider.chat([] of Hcode::LLM::Message, nil) { }
    second.tool_use?.should be_false
    second.text.should eq("done")
  end

  it "streams the step's parts through the block before returning" do
    provider = Hcode::LLM::MockProvider.new([
      Hcode::LLM::MockStep.new(
        parts: [
          Hcode::LLM::ToolCallPart.new("c1", "Glob", %({"pattern":"*"})),
          Hcode::LLM::TextPart.new("hello"),
        ] of Hcode::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "hello",
      ),
    ])

    seen = [] of Hcode::LLM::MessagePart
    provider.chat([] of Hcode::LLM::Message, nil) { |part| seen << part }

    seen.any?(&.is_a?(Hcode::LLM::ToolCallPart)).should be_true
    seen.any?(&.is_a?(Hcode::LLM::TextPart)).should be_true
    seen.last.is_a?(Hcode::LLM::FinishPart).should be_true
  end
end

describe "LLM provider registry" do
  it "defaults to the moonshot provider" do
    Hcode::LLM::DEFAULT_PROVIDER_NAME.should eq("moonshot")
  end

  it "lists moonshot, zai and mock among the known providers" do
    names = Hcode::LLM::KNOWN_PROVIDERS.map(&.name)
    names.should contain("moonshot")
    names.should contain("zai")
    names.should contain("mock")
  end

  it "recognises known providers and rejects unknown ones" do
    Hcode::LLM.known_provider?("moonshot").should be_true
    Hcode::LLM.known_provider?("zai").should be_true
    Hcode::LLM.known_provider?("mock").should be_true
    Hcode::LLM.known_provider?("nope").should be_false
  end
end

describe "LLM model registry" do
  it "MockProvider returns its model id from fetch_models" do
    provider = Hcode::LLM::MockProvider.new
    provider.fetch_models.should eq(["mock"])
  end

  it "fetch_models respects a custom model name on MockProvider" do
    provider = Hcode::LLM::MockProvider.new(model: "custom-mock")
    provider.fetch_models.should eq(["custom-mock"])
  end
end

describe "OpenAIChatProvider request shaping" do
  it "MoonshotProvider sends prompt_cache_key, thinking and max_completion_tokens" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.prompt_cache_key = "sess-abc"
    provider.thinking_effort = "medium"
    provider.max_context_tokens = 131072
    provider.used_context_tokens = 1000

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    json["prompt_cache_key"].should eq("sess-abc")
    json["thinking"]["type"].should eq("enabled")
    json["stream_options"]["include_usage"].should be_true
    # Moonshot transport speaks max_completion_tokens (not the legacy alias).
    json.as_h.has_key?("max_completion_tokens").should be_true
    json.as_h.has_key?("max_tokens").should be_false
    # Clamped to the remaining window (131072 - 1000).
    json["max_completion_tokens"].should eq(130072)
  end

  it "MoonshotProvider omits effort for boolean-only models (hcode-for-coding has no valid_efforts)" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.thinking_effort = "medium"

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("enabled")
    # No model metadata fetched → treated as boolean-only → no effort field,
    # otherwise the endpoint rejects "medium" with HTTP 400.
    json["thinking"].as_h.has_key?("effort").should be_false
  end

  it "MoonshotProvider sends effort when the model declares it in valid_efforts" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "k3")
    provider.thinking_effort = "high"
    provider.valid_efforts = ["low", "high", "max"]
    provider.default_effort = "max"

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("enabled")
    json["thinking"]["effort"].should eq("high")
  end

  it "MoonshotProvider falls back to default_effort when the requested one is unsupported" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "k3")
    provider.thinking_effort = "medium" # not in valid_efforts
    provider.valid_efforts = ["low", "high", "max"]
    provider.default_effort = "max"

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("enabled")
    json["thinking"]["effort"].should eq("max")
  end

  it "MoonshotProvider disables thinking for the off token" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    provider.thinking_effort = "off"

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("disabled")
    json["thinking"].as_h.has_key?("effort").should be_false
  end

  it "ZaiProvider uses the legacy max_tokens alias and sends reasoning_effort" do
    provider = Hcode::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.prompt_cache_key = "sess-xyz"
    provider.thinking_effort = "medium"
    provider.max_context_tokens = 131072

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    # prompt_cache_key is harmless for OpenAI-compatible endpoints and is sent.
    json["prompt_cache_key"].should eq("sess-xyz")
    # GLM speaks top-level reasoning_effort, not the Moonshot thinking object.
    json["reasoning_effort"].should eq("medium")
    json.as_h.has_key?("thinking").should be_false
    # Plain OpenAI-compatible backend → legacy max_tokens, not max_completion_tokens.
    json.as_h.has_key?("max_tokens").should be_true
    json.as_h.has_key?("max_completion_tokens").should be_false
  end

  it "ZaiProvider omits reasoning_effort for off/on tokens" do
    provider = Hcode::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.thinking_effort = "on"

    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)

    json.as_h.has_key?("reasoning_effort").should be_false
    json.as_h.has_key?("thinking").should be_false
  end

  it "leaves the completion budget unset when no context window is configured" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)
    json.as_h.has_key?("max_completion_tokens").should be_false
    json.as_h.has_key?("max_tokens").should be_false
  end

  it "enables parallel_tool_calls when tools are present" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    tool = Hcode::LLM::ToolDefinition.new(Hcode::LLM::ToolFunction.new("Read", "reads", JSON.parse("{}")))
    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], [tool]).to_json)
    json["parallel_tool_calls"].should be_true
  end

  it "omits parallel_tool_calls when no tools are present" do
    provider = Hcode::LLM::MoonshotProvider.new(model: "hcode-for-coding")
    json = JSON.parse(provider.build_request([Hcode::LLM::Message.user("hi")], nil).to_json)
    json.as_h.has_key?("parallel_tool_calls").should be_false
  end
end
