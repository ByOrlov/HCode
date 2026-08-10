require "../spec_helper"
require "../../src/tools/web_search"
require "../support/mock_http_transport"

private class FakeProvider < Hcode::Tools::WebSearchProvider
  def initialize(@behaviour : Proc(String, Array(Hcode::Tools::WebSearchResult)))
  end

  def search(query : String, tool_call_id : String? = nil, signal : Hcode::Tools::AbortController? = nil) : Array(Hcode::Tools::WebSearchResult)
    @behaviour.call(query)
  end
end

private class FakeService < Hcode::Tools::WebSearchProviderService
  def initialize(@provider : Hcode::Tools::WebSearchProvider?)
  end

  def get_web_search_provider : Hcode::Tools::WebSearchProvider?
    @provider
  end
end

describe Hcode::Tools::WebSearch do
  after_each do
    Hcode::Tools::WebSearch.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::WebSearch.new
    tool.name.should eq("WebSearch")
    tool.description.should contain("up-to-date information")
    props = tool.parameters["properties"].as_h
    props.has_key?("query").should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "returns NO_RESULTS_MESSAGE on empty list" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) { [] of Hcode::Tools::WebSearchResult }))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_false
    result.content.should eq("No search results found.")
  end

  it "renders list with site/date when present" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) do
      [
        Hcode::Tools::WebSearchResult.new(title: "T1", url: "https://a.com", snippet: "S1",
          site_name: "SiteA", date: "2026-01-01"),
        Hcode::Tools::WebSearchResult.new(title: "T2", url: "https://b.com", snippet: "S2"),
      ]
    end))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_false
    result.content.should contain("Title: T1")
    result.content.should contain("Site: SiteA")
    result.content.should contain("Date: 2026-01-01")
    result.content.should contain("URL: https://a.com")
    result.content.should contain("Snippet: S1")
    result.content.should contain("---")
    result.content.should contain("Title: T2")
    # No Site/Date lines for second result.
    lines = result.content.lines
    second_idx = lines.index("Title: T2") || raise "Title: T2 not found"
    ["Site:", "Date:"].each do |needle|
      lines[second_idx + 1].should_not contain(needle)
    end
    result.content.should contain("cite its source URL")
  end

  it "classifies 401 error as authentication failure" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) do
      raise Exception.new("HTTP 401 unauthorized")
    end))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_true
    result.content.should contain("Search failed (authentication)")
  end

  it "classifies network error" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) do
      raise Exception.new("Connection refused: network")
    end))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_true
    result.content.should contain("Search failed (network)")
  end

  it "classifies timeout error" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) do
      raise Exception.new("request timed out")
    end))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_true
    result.content.should contain("Search timed out")
  end

  it "falls back to generic failure message" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) do
      raise Exception.new("internal server error")
    end))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_true
    result.content.should contain("Search failed:")
    result.content.should contain("internal server error")
  end

  it "returns error when no provider is configured" do
    Hcode::Tools::WebSearch.service = FakeService.new(nil)

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_true
    result.content.should contain("no search provider is configured")
  end

  it "truncates very large result sets" do
    Hcode::Tools::WebSearch.service = FakeService.new(FakeProvider.new(->(_q : String) do
      (1..200).map do |i|
        Hcode::Tools::WebSearchResult.new(title: "T#{i}", url: "https://#{i}.com", snippet: "S" * 300)
      end.to_a
    end))

    tool = Hcode::Tools::WebSearch.new
    result = tool.execute(JSON.parse(%({ "query": "x" })))
    result.is_error?.should be_false
    result.content.size.should be < (Hcode::Tools::WebSearch::MAX_CHARS + 200)
    result.content.should contain(Hcode::Tools::WebSearch::TRUNCATION_MARKER)
    result.truncated?.should be_true
  end
end

describe Hcode::Tools::MoonshotWebSearchProvider do
  it "parses results with all fields" do
    json = %({
      "search_results": [
        {"title": "T", "url": "https://x.com", "snippet": "S",
         "date": "2026-01-01", "site_name": "X"},
        {"title": "T2", "url": "https://y.com"}
      ]
    })
    provider = Hcode::Tools::MoonshotWebSearchProvider.new("https://example.com/search", "key")
    results = provider.parse_results(json)
    results.size.should eq(2)
    results[0].title.should eq("T")
    results[0].site_name.should eq("X")
    results[0].date.should eq("2026-01-01")
    results[1].snippet.should eq("")
    results[1].site_name.should be_nil
    results[1].date.should be_nil
  end

  it "handles missing search_results" do
    provider = Hcode::Tools::MoonshotWebSearchProvider.new("https://example.com/search", "key")
    results = provider.parse_results(%({"foo":"bar"}))
    results.should be_empty
  end

  it "uses injected transport and parses results" do
    transport = Hcode::MockHttpTransport.new
    transport.response_status = 200
    transport.response_body = %({
      "search_results": [
        {"title": "T", "url": "https://x.com", "snippet": "S"}
      ]
    })

    provider = Hcode::Tools::MoonshotWebSearchProvider.new(
      "https://example.com/search", "key", transport: transport)
    results = provider.search("query")
    results.size.should eq(1)
    results[0].title.should eq("T")
    (transport.last_body || "").should contain("query")
  end

  it "raises when transport returns 401" do
    transport = Hcode::MockHttpTransport.new
    transport.response_status = 401
    transport.response_body = "unauthorized"

    provider = Hcode::Tools::MoonshotWebSearchProvider.new(
      "https://example.com/search", "key", transport: transport)
    error = expect_raises(Exception) do
      provider.search("query")
    end
    (error.message || "").should contain("401")
  end

  it "surfaces IO::Error (network drop) from transport" do
    transport = Hcode::MockHttpTransport.new
    transport.request_error = IO::Error.new("Connection reset")

    provider = Hcode::Tools::MoonshotWebSearchProvider.new(
      "https://example.com/search", "key", transport: transport)
    error = expect_raises(IO::Error) do
      provider.search("query")
    end
    (error.message || "").should contain("Connection reset")
  end

  it "uses token_provider when api_key is absent" do
    transport = Hcode::MockHttpTransport.new
    transport.response_status = 200
    transport.response_body = %({"search_results":[{"title":"T","url":"https://x.com","snippet":"S"}]})

    calls = 0
    token_provider = -> {
      calls += 1
      "oauth-token"
    }
    provider = Hcode::Tools::MoonshotWebSearchProvider.new(
      "https://example.com/search",
      token_provider: token_provider,
      transport: transport)
    results = provider.search("query")
    results.size.should eq(1)
    calls.should eq(1)
    auth = transport.last_headers.try(&.["Authorization"]?) || ""
    auth.should contain("oauth-token")
  end
end

describe Hcode::Tools::ProviderWebSearchService do
  it "returns nil for zai provider" do
    llm = Hcode::LLM::ZaiProvider.new(
      model: "glm-4.6",
      endpoint: "https://api.z.ai/api/paas/v4",
      api_key: "sk-test",
      provider_label: "zai")
    service = Hcode::Tools::ProviderWebSearchService.new(llm)
    service.get_web_search_provider.should be_nil
  end

  it "returns nil for zai-coding-plan provider" do
    llm = Hcode::LLM::ZaiProvider.new(
      model: "glm-5.2",
      endpoint: "https://api.z.ai/api/coding/paas/v4",
      api_key: "sk-test",
      provider_label: "zai-coding-plan")
    service = Hcode::Tools::ProviderWebSearchService.new(llm)
    service.get_web_search_provider.should be_nil
  end

  it "returns nil for providers without native search" do
    llm = Hcode::LLM::MockProvider.new
    service = Hcode::Tools::ProviderWebSearchService.new(llm)
    service.get_web_search_provider.should be_nil
  end

  it "builds a Moonshot search provider from the active provider" do
    llm = Hcode::LLM::MoonshotProvider.new(
      model: "kimi-for-coding",
      endpoint: "https://api.kimi.com/coding/v1",
      api_key: "sk-test")
    service = Hcode::Tools::ProviderWebSearchService.new(llm)
    search = service.get_web_search_provider
    search.should be_a(Hcode::Tools::MoonshotWebSearchProvider)
  end

  it "returns nil for Moonshot without credentials" do
    llm = Hcode::LLM::MoonshotProvider.new(
      model: "kimi-for-coding",
      endpoint: "https://api.kimi.com/coding/v1",
      api_key: "")
    service = Hcode::Tools::ProviderWebSearchService.new(llm)
    service.get_web_search_provider.should be_nil
  end
end

describe Hcode::Tools::CompositeWebSearchService do
  it "prefers the config service over the provider service" do
    config_provider = FakeProvider.new(->(_q : String) { [] of Hcode::Tools::WebSearchResult })
    config_service = FakeService.new(config_provider)
    provider_service = FakeService.new(nil)

    composite = Hcode::Tools::CompositeWebSearchService.new(config_service, provider_service)
    composite.get_web_search_provider.should be(config_provider)
  end

  it "falls back to the provider service when config returns nil" do
    config_service = FakeService.new(nil)
    provider_provider = FakeProvider.new(->(_q : String) { [] of Hcode::Tools::WebSearchResult })
    provider_service = FakeService.new(provider_provider)

    composite = Hcode::Tools::CompositeWebSearchService.new(config_service, provider_service)
    composite.get_web_search_provider.should be(provider_provider)
  end

  it "returns nil when neither service has a provider" do
    config_service = FakeService.new(nil)
    provider_service = FakeService.new(nil)

    composite = Hcode::Tools::CompositeWebSearchService.new(config_service, provider_service)
    composite.get_web_search_provider.should be_nil
  end
end
