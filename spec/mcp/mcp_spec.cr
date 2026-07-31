require "../spec_helper"
require "file_utils"
include FileUtils

module Hcode
  module Mcp
    # In-process loopback transport: when a request (with id + method) is
    # written, it enqueues a canned response built by the registered handler.
    # This drives the JSON-RPC client end-to-end without spawning a process.
    class SmartLoopback < Transport
      getter captured = [] of String
      getter handlers = {} of String => (JSON::Any -> JSON::Any)
      @read = Channel(String).new(64)
      @closed = false

      def write_line(json : String) : Nil
        @captured << json
        msg = (JSON.parse(json) rescue nil)
        return unless msg && msg["id"]? && msg["method"]?
        method_name = msg["method"].to_s
        return unless handler = @handlers[method_name]?
        id = msg["id"].as_i
        params = msg["params"]? || JSON.parse("{}")
        result = handler.call(params)
        # If the handler returns an {"error": ...} object, surface it as a
        # JSON-RPC error envelope so the client's error path is exercised.
        if err = result["error"]?
          @read.send(%({"jsonrpc":"2.0","id":#{id},"error":#{err.to_json}}))
        else
          @read.send(%({"jsonrpc":"2.0","id":#{id},"result":#{result.to_json}}))
        end
      end

      def read_line? : String?
        @read.receive?
      end

      def close : Nil
        @closed = true
        @read.close
      end

      def closed? : Bool
        @closed
      end
    end

    describe Mcp do
      # --------------------------------------------------------------------
      # Tool naming
      # --------------------------------------------------------------------
      describe ToolNaming do
        it "composes mcp__<server>__<tool>" do
          ToolNaming.proxy_name("github", "create_issue").should eq("mcp__github__create_issue")
        end

        it "sanitizes non-word characters" do
          ToolNaming.proxy_name("my-server", "tool.name").should eq("mcp__my_server__tool_name")
        end

        it "truncates overlong names below the limit with a hash suffix" do
          long = ToolNaming.proxy_name("s" * 30, "t" * 60)
          long.size.should be <= ToolNaming::MAX_LENGTH
          long.should start_with("mcp__")
        end

        it "round-trips through split" do
          proxy = ToolNaming.proxy_name("postgres", "query")
          ToolNaming.split(proxy).should eq({"postgres", "query"})
        end

        it "split rejects non-mcp names" do
          ToolNaming.split("Bash").should be_nil
        end

        it "preserves distinctness for different long tools" do
          a = ToolNaming.proxy_name("server", ("a" * 80))
          b = ToolNaming.proxy_name("server", ("b" * 80))
          a.should_not eq(b)
        end
      end

      # --------------------------------------------------------------------
      # Config loading
      # --------------------------------------------------------------------
      describe ConfigLoader do
        it "parses the [[mcp_servers]] toml section with args + env" do
          toml = <<-TOML
            [[mcp_servers]]
            name = "github"
            command = "npx"
            args = ["-y", "@modelcontextprotocol/server-github"]
            env = { GITHUB_TOKEN = "ghp_secret" }

            [[mcp_servers]]
            name = "empty"
          TOML
          servers = ConfigLoader.parse_toml_section(toml)
          servers.size.should eq(2)
          gh = servers.find { |s| s.name == "github" }.not_nil!
          gh.command.should eq("npx")
          gh.args.should eq(["-y", "@modelcontextprotocol/server-github"])
          gh.env["GITHUB_TOKEN"].should eq("ghp_secret")
          gh.stdio?.should be_true
          servers.find(&.name.==("empty")).not_nil!.command.should eq("")
        end

        it "parses mcp.json (mcpServers object)" do
          home = File.join(Dir.tempdir, "hcode-mcp-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "remote": {
                    "command": "node",
                    "args": ["srv.js"],
                    "env": { "DEBUG": "1" }
                  }
                }
              }
            JSON
            servers = ConfigLoader.parse_mcp_json(home)
            servers.size.should eq(1)
            r = servers.first
            r.name.should eq("remote")
            r.command.should eq("node")
            r.args.should eq(["srv.js"])
            r.env["DEBUG"].should eq("1")
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "merges toml + mcp.json by name (json wins)" do
          home = File.join(Dir.tempdir, "hcode-mcp-#{Random::Secure.hex(8)}")
          hcode_home = File.join(home, ".hcode")
          Dir.mkdir_p(hcode_home)
          begin
            File.write(File.join(hcode_home, "mcp.json"), <<-JSON)
              { "mcpServers": { "github": { "command": "node", "args": [] } } }
            JSON
            toml = <<-TOML
              [[mcp_servers]]
              name = "github"
              command = "npx"

              [[mcp_servers]]
              name = "postgres"
              command = "pg-mcp"
            TOML
            merged = ConfigLoader.load(toml, home, cwd: home)
            names = merged.map(&.name).sort!
            names.should eq(["github", "postgres"])
            gh = merged.find(&.name.==("github")).not_nil!
            # json entry overrides the toml command
            gh.command.should eq("node")
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "tolerates a malformed toml section" do
          ConfigLoader.parse_toml_section("this is not toml = = =").should be_empty
          ConfigLoader.parse_toml_section(nil).should be_empty
        end
      end

      # --------------------------------------------------------------------
      # JSON-RPC client + MCP client (loopback)
      # --------------------------------------------------------------------
      describe JsonRpcClient do
        it "correlates requests by id and returns the result" do
          t = SmartLoopback.new
          t.handlers["ping"] = ->(p : JSON::Any) { JSON.parse(%({"pong": 1})) }
          rpc = JsonRpcClient.new(t)

          result = rpc.call("ping")
          result["pong"].as_i.should eq(1)
          # The request envelope was written with jsonrpc 2.0 and an id.
          req = JSON.parse(t.captured.first)
          req["jsonrpc"].to_s.should eq("2.0")
          req["method"].to_s.should eq("ping")
          req["id"]?.should_not be_nil
        end

        it "raises RpcError on an error envelope" do
          t = SmartLoopback.new
          t.handlers["boom"] = ->(p : JSON::Any) {
            JSON.parse(%({"error":{"code":-32000,"message":"kaboom"}}))
          }
          rpc = JsonRpcClient.new(t)
          expect_raises(RpcError, /kaboom/) do
            rpc.call("boom")
          end
        end

        it "sends notifications without an id" do
          t = SmartLoopback.new
          rpc = JsonRpcClient.new(t)
          rpc.notify("notifications/initialized")
          msg = JSON.parse(t.captured.first)
          msg["method"].to_s.should eq("notifications/initialized")
          msg["id"]?.should be_nil
        end
      end

      describe Client do
        it "connects, lists tools, and calls a tool (text result)" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(p : JSON::Any) {
            JSON.parse(%({"protocolVersion":"2025-06-18","capabilities":{}}))
          }
          t.handlers["tools/list"] = ->(p : JSON::Any) {
            JSON.parse(%({"tools":[{"name":"echo","description":"echoes","inputSchema":{"type":"object"}}]}))
          }
          t.handlers["tools/call"] = ->(p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"hello"}],"isError":false}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))

          client.connect
          client.initialized?.should be_true

          defs = client.list_tools
          defs.size.should eq(1)
          d = defs.first
          d.name.should eq("echo")
          d.input_schema["type"].to_s.should eq("object")

          res = client.call_tool("echo", JSON.parse(%({"x":1})))
          res.text.should eq("hello")
          res.is_error?.should be_false
        end

        it "embeds image/audio/resource content blocks as data URIs and text" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"ok"},{"type":"image","mimeType":"image/png","data":"iVBOR"},{"type":"resource","resource":{"uri":"file:///a","text":"res-text"}}]}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("img", JSON.parse("{}"))
          res.text.should contain("ok")
          res.text.should contain("data:image/png;base64,iVBOR")
          res.text.should contain("res-text")
        end

        it "decodes resource blob as data URI" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"resource","resource":{"uri":"file:///b","mimeType":"application/pdf","blob":"SEVMTE8="}}]}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("r", JSON.parse("{}"))
          res.text.should contain("data:application/pdf;base64,SEVMTE8=")
        end

        it "propagates isError from the server" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"boom"}],"isError":true}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("f", JSON.parse("{}"))
          res.is_error?.should be_true
          res.text.should eq("boom")
        end
      end

      # --------------------------------------------------------------------
      # Proxy tool
      # --------------------------------------------------------------------
      describe McpProxyTool do
        it "executes via the client and maps errors to ToolResult.error" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(p : JSON::Any) {
            JSON.parse(%({"tools":[{"name":"echo","description":"d","inputSchema":{"type":"object"}}]}))
          }
          t.handlers["tools/call"] = ->(p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"42"}]}))
          }
          client = Client.new("srv", t, JsonRpcClient.new(t))
          proxy = McpProxyTool.new(
            "mcp__srv__echo", "srv", "echo", "d",
            JSON.parse(%({"type":"object"})), client)

          proxy.name.should eq("mcp__srv__echo")
          proxy.description.should eq("d")
          r = proxy.execute(JSON.parse(%({"q":1})))
          r.is_error.should be_false
          r.content.should eq("42")
        end
      end

      # --------------------------------------------------------------------
      # Manager (no real servers)
      # --------------------------------------------------------------------
      describe Manager do
        it "reports empty state when nothing is configured" do
          m = Manager.new
          m.connect_all([] of McpServerConfig, Tools::Registry.new)
          m.any_connected?.should be_false
          m.status_text.should eq("No MCP servers configured.")
        end

        it "fails an HTTP server with no url" do
          m = Manager.new
          cfg = McpServerConfig.new("remote", type: "http")
          m.connect_all([cfg], Tools::Registry.new)
          m.any_connected?.should be_false
          m.status_text.should contain("no `url`")
        end

        it "fails a server with no command" do
          m = Manager.new
          cfg = McpServerConfig.new("empty")
          m.connect_all([cfg], Tools::Registry.new)
          m.any_connected?.should be_false
          m.status_text.should contain("no `command`")
        end
      end

      # --------------------------------------------------------------------
      # SSE parsing (Phase 2)
      # --------------------------------------------------------------------
      describe "SSE parsing" do
        it "extracts data: payloads from an event-stream body" do
          # HttpTransport#parse_sse is private; test via a thin HTTP transport
          # instance using the (url, token) test constructor.
          t = HttpTransport.new("http://localhost:1", nil)
          # Access the private method via a small wrapper.
          body = %(event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\nevent: message\ndata: {"jsonrpc":"2.0","id":2,"result":{"ok":false}}\n\n)
          events = t.parse_sse(body)
          events.size.should eq(2)
          JSON.parse(events[0])["id"].as_i.should eq(1)
          JSON.parse(events[1])["id"].as_i.should eq(2)
        end

        it "joins multi-line data: fields" do
          t = HttpTransport.new("http://localhost:1", nil)
          body = %(data: line1\ndata: line2\n\n)
          events = t.parse_sse(body)
          events.size.should eq(1)
          events[0].should eq("line1\nline2")
        end
      end

      # --------------------------------------------------------------------
      # Config OAuth fields (Phase 4)
      # --------------------------------------------------------------------
      describe ConfigLoader do
        it "parses OAuth fields from [[mcp_servers]]" do
          toml = <<-TOML
            [[mcp_servers]]
            name = "remote"
            type = "http"
            url = "https://mcp.example.com/sse"
            oauth_client_id = "my-client"
            oauth_client_secret = "secret123"
            oauth_scopes = ["read", "write"]
          TOML
          servers = ConfigLoader.parse_toml_section(toml)
          s = servers.first
          s.stdio?.should be_false
          s.url.should eq("https://mcp.example.com/sse")
          s.oauth_client_id.should eq("my-client")
          s.oauth_client_secret.should eq("secret123")
          s.oauth_scopes.should eq(["read", "write"])
          s.oauth_configured?.should be_true
        end
      end

      # --------------------------------------------------------------------
      # OAuth token persistence (Phase 4)
      # --------------------------------------------------------------------
      describe OAuth do
        it "saves and loads tokens" do
          home = File.join(Dir.tempdir, "hcode-oauth-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            tokens = OAuthTokens.new("access-123", "refresh-456", "Bearer",
                                     Time.utc.to_unix + 3600, "read")
            OAuth.save_tokens("srv", home, tokens)
            loaded = OAuth.load_tokens("srv", home)
            loaded.should_not be_nil
            loaded.not_nil!.access_token.should eq("access-123")
            loaded.not_nil!.refresh_token.should eq("refresh-456")
            loaded.not_nil!.expired?.should be_false
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "detects expired tokens" do
          tokens = OAuthTokens.new("tok", expires_at: Time.utc.to_unix - 10)
          tokens.expired?.should be_true
        end

        it "clears tokens" do
          home = File.join(Dir.tempdir, "hcode-oauth-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            tokens = OAuthTokens.new("tok")
            OAuth.save_tokens("srv", home, tokens)
            OAuth.clear_tokens("srv", home)
            OAuth.load_tokens("srv", home).should be_nil
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end
      end

      # --------------------------------------------------------------------
      # Config: enabled flag + tool filtering (JS parity)
      # --------------------------------------------------------------------
      describe McpServerConfig do
        it "disabled server is skipped" do
          cfg = McpServerConfig.new("x", command: "echo")
          cfg.enabled?.should be_true
          cfg.enabled = false
          cfg.enabled?.should be_false
        end

        it "allowed_tool_names applies enabled/disabled filters" do
          cfg = McpServerConfig.new("srv", command: "echo")
          all = ["alpha", "beta", "gamma", "delta"]
          # No filters → all allowed
          cfg.allowed_tool_names(all).should eq(Set{"alpha", "beta", "gamma", "delta"})

          # enabledTools whitelist
          cfg.enabled_tools = ["alpha", "gamma"]
          cfg.allowed_tool_names(all).should eq(Set{"alpha", "gamma"})

          # disabledTools blacklist (on top of whitelist)
          cfg.disabled_tools = ["gamma"]
          cfg.allowed_tool_names(all).should eq(Set{"alpha"})

          # Only disabledTools, no whitelist
          cfg.enabled_tools = nil
          cfg.disabled_tools = ["beta"]
          cfg.allowed_tool_names(all).should eq(Set{"alpha", "gamma", "delta"})
        end

        it "effective timeouts fall back to defaults" do
          cfg = McpServerConfig.new("srv", command: "echo")
          cfg.effective_startup_timeout(30.seconds).should eq(30.seconds)
          cfg.effective_tool_timeout.should be_nil

          cfg.startup_timeout_ms = 5000
          cfg.tool_timeout_ms = 10000
          cfg.effective_startup_timeout(30.seconds).should eq(5.seconds)
          cfg.effective_tool_timeout.should eq(10.seconds)
        end

        it "remote? distinguishes http/sse from stdio" do
          McpServerConfig.new("s", command: "c").remote?.should be_false
          McpServerConfig.new("h", type: "http", url: "http://x").remote?.should be_true
          McpServerConfig.new("h", type: "sse", url: "http://x").remote?.should be_true
        end
      end

      # --------------------------------------------------------------------
      # Output post-processing (JS parity: text budget + binary cap + media wrap)
      # --------------------------------------------------------------------
      describe Output do
        it "wraps media-only output in mcp_tool_result tags" do
          text = "data:image/png;base64,iVBOR"
          result = Output.post_process(text, "mcp__srv__screenshot")
          result.should contain("<mcp_tool_result name=\"mcp__srv__screenshot\">")
          result.should contain("</mcp_tool_result>")
        end

        it "does not wrap when text accompanies media" do
          text = "Here is the image:\ndata:image/png;base64,iVBOR"
          result = Output.post_process(text, "mcp__srv__tool")
          result.should_not contain("<mcp_tool_result")
        end

        it "truncates text exceeding the 100k char budget" do
          text = "a" * (Output::MAX_OUTPUT_CHARS + 1000)
          result = Output.post_process(text, "mcp__srv__chatty")
          result.size.should be <= Output::MAX_OUTPUT_CHARS + 200
          result.should contain("[Output truncated")
        end

        it "drops oversized binary parts" do
          huge = "data:image/png;base64," + ("A" * (Output::MAX_BINARY_PART_CHARS + 100))
          result = Output.post_process(huge, "mcp__srv__img")
          result.should contain("[binary dropped:")
          result.should_not contain("data:image/png;base64,AAAA")
        end
      end

      # --------------------------------------------------------------------
      # Manager: enabled flag (JS parity)
      # --------------------------------------------------------------------
      describe Manager do
        it "marks disabled servers as Disabled and skips connection" do
          m = Manager.new
          cfg = McpServerConfig.new("off", command: "nonexistent")
          cfg.enabled = false
          m.connect_all([cfg], Tools::Registry.new)
          m.status_text.should contain("⊘")
          m.status_text.should contain("off")
        end
      end
    end
  end
end
