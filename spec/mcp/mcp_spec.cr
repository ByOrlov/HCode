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
          ToolNaming.split(Hcode::Tools::Names::BASH).should be_nil
        end

        it "preserves distinctness for different long tools" do
          a = ToolNaming.proxy_name("server", ("a" * 80))
          b = ToolNaming.proxy_name("server", ("b" * 80))
          a.should_not eq(b)
        end

        it "collapses underscore runs so __ separator stays unambiguous" do
          # Server name with underscores must not collide with the __ separator.
          proxy = ToolNaming.proxy_name("my__server", "tool")
          split = ToolNaming.split(proxy)
          split.should eq({"my_server", "tool"})
        end

        it "sanitizes names with consecutive underscores" do
          proxy = ToolNaming.proxy_name("a___b", "c____d")
          proxy.should eq("mcp__a_b__c_d")
        end
      end

      # --------------------------------------------------------------------
      # Config loading
      # --------------------------------------------------------------------
      describe ConfigLoader do
        it "parses mcp.json with args + env" do
          home = File.join(Dir.tempdir, "hcode-mcp-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "github": {
                    "command": "npx",
                    "args": ["-y", "@modelcontextprotocol/server-github"],
                    "env": { "GITHUB_TOKEN": "ghp_secret" }
                  },
                  "empty": {}
                }
              }
            JSON
            servers = ConfigLoader.parse_mcp_json(home)
            servers.size.should eq(2)
            gh = servers.find! { |s| s.name == "github" }
            gh.command.should eq("npx")
            gh.args.should eq(["-y", "@modelcontextprotocol/server-github"])
            gh.env["GITHUB_TOKEN"].should eq("ghp_secret")
            gh.stdio?.should be_true
            servers.find!(&.name.==("empty")).command.should eq("")
          ensure
            FileUtils.rm_r(home) rescue nil
          end
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

        it "merges user + project mcp.json by name (project wins)" do
          home = File.join(Dir.tempdir, "hcode-mcp-#{Random::Secure.hex(8)}")
          hcode_home = File.join(home, ".hcode")
          Dir.mkdir_p(hcode_home)
          begin
            File.write(File.join(hcode_home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "github": { "command": "node", "args": [] },
                  "postgres": { "command": "pg-mcp" }
                }
              }
            JSON
            merged = ConfigLoader.load(home, cwd: home)
            names = merged.map(&.name).sort!
            names.should eq(["github", "postgres"])
            gh = merged.find!(&.name.==("github"))
            gh.command.should eq("node")
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "tolerates a missing mcp.json" do
          home = File.join(Dir.tempdir, "hcode-mcp-none-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            servers = ConfigLoader.load(home, cwd: home)
            servers.should be_empty
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "parses providers (array) and provider (single string) from mcp.json" do
          home = File.join(Dir.tempdir, "hcode-mcp-prov2-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "zai-search": {
                    "command": "npx",
                    "providers": ["zai", "zai-coding-plan"]
                  },
                  "single": {
                    "command": "x",
                    "provider": "moonshot"
                  }
                }
              }
            JSON
            servers = ConfigLoader.parse_mcp_json(home)
            multi = servers.find!(&.name.==("zai-search"))
            multi.providers.should eq(["zai", "zai-coding-plan"])
            single = servers.find!(&.name.==("single"))
            single.providers.should eq(["moonshot"])
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "parses toolAliases from mcp.json" do
          home = File.join(Dir.tempdir, "hcode-mcp-aliases-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "zai-web-search": {
                    "type": "http",
                    "url": "https://api.z.ai/api/mcp/web_search_prime/mcp",
                    "toolAliases": { "web_search_prime": Hcode::Tools::Names::WEB_SEARCH }
                  }
                }
              }
            JSON
            servers = ConfigLoader.parse_mcp_json(home)
            servers.size.should eq(1)
            server = servers.first
            server.tool_aliases.should eq({"web_search_prime" => Hcode::Tools::Names::WEB_SEARCH})
            server.aliased_tool_name("web_search_prime").should eq(Hcode::Tools::Names::WEB_SEARCH)
            server.aliased_tool_name("other").should eq("other")
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "parses providers from mcp.json" do
          home = File.join(Dir.tempdir, "hcode-mcp-prov-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "zai-search": {
                    "command": "npx",
                    "providers": ["zai", "zai-coding-plan"]
                  },
                  "moon-only": {
                    "command": "x",
                    "provider": "moonshot"
                  }
                }
              }
            JSON
            servers = ConfigLoader.parse_mcp_json(home)
            servers.find!(&.name.==("zai-search")).providers
              .should eq(["zai", "zai-coding-plan"])
            servers.find!(&.name.==("moon-only")).providers
              .should eq(["moonshot"])
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "resolves relative stdio cwd against the file directory" do
          home = File.join(Dir.tempdir, "hcode-mcp-cwd-#{Random::Secure.hex(8)}")
          subdir = File.join(home, "subproject")
          Dir.mkdir_p(subdir)
          begin
            File.write(File.join(subdir, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "srv": {
                    "command": "node",
                    "args": ["srv.js"],
                    "cwd": "./workspace"
                  }
                }
              }
            JSON
            servers = ConfigLoader.read_mcp_json_file(File.join(subdir, "mcp.json"))
            s = servers.first
            s.cwd.should eq(File.join(subdir, "workspace"))
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "keeps absolute stdio cwd as-is" do
          home = File.join(Dir.tempdir, "hcode-mcp-abs-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          abs = File.join(home, "absdir")
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "srv": {
                    "command": "node",
                    "cwd": #{abs.inspect}
                  }
                }
              }
            JSON
            servers = ConfigLoader.read_mcp_json_file(File.join(home, "mcp.json"))
            servers.first.cwd.should eq(abs)
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end
      end

      # --------------------------------------------------------------------
      # JSON-RPC client + MCP client (loopback)
      # --------------------------------------------------------------------
      describe JsonRpcClient do
        it "correlates requests by id and returns the result" do
          t = SmartLoopback.new
          t.handlers["ping"] = ->(_p : JSON::Any) { JSON.parse(%({"pong": 1})) }
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
          t.handlers["boom"] = ->(_p : JSON::Any) {
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
          t.handlers["initialize"] = ->(_p : JSON::Any) {
            JSON.parse(%({"protocolVersion":"2025-06-18","capabilities":{}}))
          }
          t.handlers["tools/list"] = ->(_p : JSON::Any) {
            JSON.parse(%({"tools":[{"name":"echo","description":"echoes","inputSchema":{"type":"object"}}]}))
          }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
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
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"ok"},{"type":"image","mimeType":"image/png","data":"iVBOR"},{"type":"resource","resource":{"uri":"file:///a","text":"res-text"}}]}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("img", JSON.parse("{}"))
          res.text.should contain("ok")
          res.text.should contain("data:image/png;base64,iVBOR")
          res.text.should contain("res-text")
        end

        it "handles resource_link as a URL reference, not inline blob" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"resource_link","uri":"https://example.com/img.png","mimeType":"image/png"}]}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("rl", JSON.parse("{}"))
          res.text.should contain("https://example.com/img.png")
          res.text.should_not contain("data:image/png;base64,")
        end

        it "captures negotiated protocol version from initialize" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) {
            JSON.parse(%({"protocolVersion":"2025-03-26","capabilities":{}}))
          }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.negotiated_version.should be_nil
          client.connect
          client.negotiated_version.should eq("2025-03-26")
        end

        it "decodes resource blob as data URI" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"resource","resource":{"uri":"file:///b","mimeType":"application/pdf","blob":"SEVMTE8="}}]}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("r", JSON.parse("{}"))
          res.text.should contain("data:application/pdf;base64,SEVMTE8=")
        end

        it "propagates isError from the server" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"boom"}],"isError":true}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("f", JSON.parse("{}"))
          res.is_error?.should be_true
          res.text.should eq("boom")
        end

        it "handles legacy { toolResult } shape" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"toolResult":"legacy string result"}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("legacy", JSON.parse("{}"))
          res.text.should eq("legacy string result")
          res.is_error?.should be_false
        end

        it "handles legacy { toolResult } with object" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) { JSON.parse(%({"tools":[]})) }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"toolResult":{"key":"val"}}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          res = client.call_tool("legacy", JSON.parse("{}"))
          res.text.should contain("key")
          res.text.should contain("val")
        end

        it "defaults non-object inputSchema to empty object" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) {
            JSON.parse(%({"tools":[{"name":"bad","description":"d","inputSchema":null},{"name":"arr","description":"d","inputSchema":[1,2]},{"name":"ok","description":"d","inputSchema":{"type":"object"}}]}))
          }
          client = Client.new("test", t, JsonRpcClient.new(t))
          client.connect
          defs = client.list_tools
          defs.size.should eq(3)
          defs[0].input_schema.to_json.should eq("{}")
          defs[1].input_schema.to_json.should eq("{}")
          defs[2].input_schema["type"].to_s.should eq("object")
        end
      end

      # --------------------------------------------------------------------
      # Proxy tool
      # --------------------------------------------------------------------
      describe McpProxyTool do
        it "executes via the client and maps errors to ToolResult.error" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) {
            JSON.parse(%({"tools":[{"name":"echo","description":"d","inputSchema":{"type":"object"}}]}))
          }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"42"}]}))
          }
          client = Client.new("srv", t, JsonRpcClient.new(t))
          proxy = McpProxyTool.new(
            "mcp__srv__echo", "srv", "echo", "d",
            JSON.parse(%({"type":"object"})), client)

          proxy.name.should eq("mcp__srv__echo")
          proxy.description.should eq("d")
          r = proxy.execute(JSON.parse(%({"q":1})))
          r.is_error?.should be_false
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
          m.connect_all([cfg], Tools::Registry.new, blocking: true)
          m.any_connected?.should be_false
          m.status_text.should contain("no `url`")
        end

        it "fails a server with no command" do
          m = Manager.new
          cfg = McpServerConfig.new("empty")
          m.connect_all([cfg], Tools::Registry.new, blocking: true)
          m.any_connected?.should be_false
          m.status_text.should contain("no `command`")
        end

        it "filters out servers whose provider does not match" do
          m = Manager.new
          zai = McpServerConfig.new("zai-search", command: "no-such-cmd",
            providers: ["zai", "zai-coding-plan"])
          m.connect_all([zai], Tools::Registry.new,
            active_provider: "moonshot", blocking: true)
          m.any_connected?.should be_false
          m.status_text.should eq("No MCP servers configured.")
        end

        it "connects global servers regardless of provider" do
          m = Manager.new
          global = McpServerConfig.new("global", command: "no-such-cmd")
          m.connect_all([global], Tools::Registry.new,
            active_provider: "moonshot", blocking: true)
          # It attempts connection (fails on missing binary) but is not filtered.
          m.status_text.should contain("global")
          m.status_text.should_not contain("No MCP servers configured.")
        end

        it "uses toolAliases when registering cached proxy tools" do
          home = File.join(Dir.tempdir, "hcode-mcp-alias-#{Random::Secure.hex(8)}")
          ENV["HCODE_HOME"] = home
          Dir.mkdir_p(home)
          begin
            defs = [
              ToolDefinition.new("web_search_prime", "Search the web",
                JSON.parse(%({"type":"object"}))),
            ]
            ToolCache.save("zai-coding-plan", "zai-web-search", defs)

            m = Manager.new(home)
            cfg = McpServerConfig.new("zai-web-search", type: "http",
              url: "https://api.z.ai/api/mcp/web_search_prime/mcp",
              providers: ["zai-coding-plan"],
              tool_aliases: {"web_search_prime" => Hcode::Tools::Names::WEB_SEARCH})
            reg = Tools::Registry.new
            m.register_from_cache([cfg], reg,
              active_provider: "zai-coding-plan", blocking: true)

            reg.get("mcp__zai_web_search__WebSearch").should_not be_nil
            reg.get("mcp__zai_web_search__web_search_prime").should be_nil
          ensure
            ENV.delete("HCODE_HOME")
            rm_r(home) rescue nil
          end
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
        it "parses OAuth fields from mcp.json" do
          home = File.join(Dir.tempdir, "hcode-oauth-cfg-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(home)
          begin
            File.write(File.join(home, "mcp.json"), <<-JSON)
              {
                "mcpServers": {
                  "remote": {
                    "type": "http",
                    "url": "https://mcp.example.com/sse",
                    "oauth_client_id": "my-client",
                    "oauth_client_secret": "secret123",
                    "oauth_scopes": ["read", "write"]
                  }
                }
              }
            JSON
            servers = ConfigLoader.parse_mcp_json(home)
            s = servers.first
            s.stdio?.should be_false
            s.url.should eq("https://mcp.example.com/sse")
            s.oauth_client_id.should eq("my-client")
            s.oauth_client_secret.should eq("secret123")
            s.oauth_scopes.should eq(["read", "write"])
            s.oauth_configured?.should be_true
          ensure
            FileUtils.rm_r(home) rescue nil
          end
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
            OAuth.save_tokens("srv", "https://mcp.example.com", home, tokens)
            loaded = OAuth.load_tokens("srv", "https://mcp.example.com", home)
            loaded.should_not be_nil
            if l = loaded
              l.access_token.should eq("access-123")
              l.refresh_token.should eq("refresh-456")
              l.expired?.should be_false
            end
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
            OAuth.save_tokens("srv", "https://mcp.example.com", home, tokens)
            OAuth.clear_tokens("srv", "https://mcp.example.com", home)
            OAuth.load_tokens("srv", "https://mcp.example.com", home).should be_nil
          ensure
            FileUtils.rm_r(home) rescue nil
          end
        end

        it "store key includes URL digest (different URLs → different files)" do
          key1 = OAuth.store_key("srv", "https://mcp.example.com/v1")
          key2 = OAuth.store_key("srv", "https://mcp.example.com/v2")
          key1.should_not eq(key2)
          key1.should start_with("srv-")
        end

        it "store key is stable for same name + URL" do
          key1 = OAuth.store_key("srv", "https://mcp.example.com")
          key2 = OAuth.store_key("srv", "https://mcp.example.com")
          key1.should eq(key2)
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

        it "matches_provider? treats empty providers as global" do
          cfg = McpServerConfig.new("g", command: "c")
          cfg.matches_provider?("moonshot").should be_true
          cfg.matches_provider?("zai").should be_true
          cfg.matches_provider?(nil).should be_true
        end

        it "matches_provider? only matches listed providers" do
          cfg = McpServerConfig.new("z", command: "c", providers: ["zai", "zai-coding-plan"])
          cfg.matches_provider?("zai").should be_true
          cfg.matches_provider?("zai-coding-plan").should be_true
          cfg.matches_provider?("moonshot").should be_false
          cfg.matches_provider?(nil).should be_false
        end
      end

      # --------------------------------------------------------------------
      # Output post-processing (JS parity: text budget + binary cap + media wrap)
      # --------------------------------------------------------------------
      describe Output do
        it "wraps media-only output in mcp_tool_result tags" do
          text = "data:image/png;base64,iVBOR"
          result = Output.post_process(text, "mcp__srv__screenshot")
          result[:text].should contain("<mcp_tool_result name=\"mcp__srv__screenshot\">")
          result[:text].should contain("</mcp_tool_result>")
        end

        it "does not wrap when text accompanies media" do
          text = "Here is the image:\ndata:image/png;base64,iVBOR"
          result = Output.post_process(text, "mcp__srv__tool")
          result[:text].should_not contain("<mcp_tool_result")
        end

        it "truncates text exceeding the 100k char budget" do
          text = "a" * (Output::MAX_OUTPUT_CHARS + 1000)
          result = Output.post_process(text, "mcp__srv__chatty")
          result[:text].size.should be <= Output::MAX_OUTPUT_CHARS + 200
          result[:text].should contain("[Output truncated")
          result[:truncated].should be_true
        end

        it "drops oversized binary parts" do
          huge = "data:image/png;base64," + ("A" * (Output::MAX_BINARY_PART_CHARS + 100))
          result = Output.post_process(huge, "mcp__srv__img")
          result[:text].should contain("[binary dropped:")
          result[:text].should_not contain("data:image/png;base64,AAAA")
          result[:truncated].should be_true
        end

        it "returns truncated=false for small text" do
          result = Output.post_process("hello world", "mcp__srv__t")
          result[:truncated].should be_false
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
          m.connect_all([cfg], Tools::Registry.new, blocking: true)
          m.status_text.should contain("⊘")
          m.status_text.should contain("off")
        end
      end

      # --------------------------------------------------------------------
      # Proxy tool: truncated flag propagation (fix 8)
      # --------------------------------------------------------------------
      describe McpProxyTool do
        it "propagates truncated flag on oversized output" do
          t = SmartLoopback.new
          t.handlers["initialize"] = ->(_p : JSON::Any) { JSON.parse("{}") }
          t.handlers["tools/list"] = ->(_p : JSON::Any) {
            JSON.parse(%({"tools":[{"name":"chatty","description":"d","inputSchema":{"type":"object"}}]}))
          }
          t.handlers["tools/call"] = ->(_p : JSON::Any) {
            JSON.parse(%({"content":[{"type":"text","text":"#{("a" * (Output::MAX_OUTPUT_CHARS + 500))}"}]}))
          }
          client = Client.new("srv", t, JsonRpcClient.new(t))
          proxy = McpProxyTool.new(
            "mcp__srv__chatty", "srv", "chatty", "d",
            JSON.parse(%({"type":"object"})), client)

          r = proxy.execute(JSON.parse("{}"))
          r.truncated?.should be_true
        end
      end

      # --------------------------------------------------------------------
      # Registry: unregister (needed for MCP provider reconcile)
      # --------------------------------------------------------------------
      describe Tools::Registry do
        it "removes a tool by name via unregister" do
          reg = Tools::Registry.new
          tool = McpProxyTool.new("mcp__srv__echo", "srv", "echo", "d",
            JSON.parse(%({"type":"object"})),
            Client.new("srv", SmartLoopback.new,
              JsonRpcClient.new(SmartLoopback.new)))
          reg.register(tool)
          reg.get("mcp__srv__echo").should_not be_nil
          reg.unregister("mcp__srv__echo")
          reg.get("mcp__srv__echo").should be_nil
        end
      end
    end

    # --------------------------------------------------------------------
    # Tool cache (lazy MCP)
    # --------------------------------------------------------------------
    describe ToolCache do
      it "saves and loads tool definitions" do
        home = File.join(Dir.tempdir, "hcode-tc-#{Random::Secure.hex(8)}")
        ENV["HCODE_HOME"] = home
        Dir.mkdir_p(home)
        begin
          defs = [
            ToolDefinition.new("search", "Search the web", JSON.parse(%({"type":"object"}))),
            ToolDefinition.new("read", "Read a page", JSON.parse(%({"type":"object","properties":{}}))),
          ]
          ToolCache.save("zai-coding-plan", "web-search", defs)

          loaded = ToolCache.load?("zai-coding-plan", "web-search")
          loaded.should_not be_nil
          if l = loaded
            l.size.should eq(2)
            l[0].name.should eq("search")
            l[0].description.should eq("Search the web")
            l[1].name.should eq("read")
          end
        ensure
          ENV.delete("HCODE_HOME")
          rm_r(home) rescue nil
        end
      end

      it "returns nil for unknown provider/server" do
        home = File.join(Dir.tempdir, "hcode-tc-#{Random::Secure.hex(8)}")
        ENV["HCODE_HOME"] = home
        Dir.mkdir_p(home)
        begin
          ToolCache.load?("unknown", "nope").should be_nil
        ensure
          ENV.delete("HCODE_HOME")
          rm_r(home) rescue nil
        end
      end

      it "clears one server or all servers for a provider" do
        home = File.join(Dir.tempdir, "hcode-tc-#{Random::Secure.hex(8)}")
        ENV["HCODE_HOME"] = home
        Dir.mkdir_p(home)
        begin
          defs = [ToolDefinition.new("t1", "d1", JSON.parse("{}"))]
          ToolCache.save("prov", "srv1", defs)
          ToolCache.save("prov", "srv2", defs)

          ToolCache.clear("prov", "srv1")
          ToolCache.load?("prov", "srv1").should be_nil
          ToolCache.load?("prov", "srv2").should_not be_nil

          ToolCache.clear("prov")
          ToolCache.load?("prov", "srv2").should be_nil
        ensure
          ENV.delete("HCODE_HOME")
          rm_r(home) rescue nil
        end
      end
    end

    # --------------------------------------------------------------------
    # McpLazyProxyTool
    # --------------------------------------------------------------------
    describe McpLazyProxyTool do
      it "exposes static identity without a client" do
        manager = Manager.new(Dir.tempdir)
        tool = McpLazyProxyTool.new(
          "mcp__srv__search", "srv", "search",
          "Search the web", JSON.parse(%({"type":"object"})),
          manager
        )
        tool.name.should eq("mcp__srv__search")
        tool.description.should eq("Search the web")
        tool.parameters["type"].to_s.should eq("object")
      end
    end
  end
end
