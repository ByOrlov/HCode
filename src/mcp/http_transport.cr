require "http/client"
require "uri"
require "base64"
require "./transport"
require "./config"

module H2code
  module Mcp
    # Streamable HTTP transport (MCP spec, 2025-03-26 edition). Each JSON-RPC
    # message is sent as an HTTP POST to the configured endpoint. The server
    # responds either with inline JSON (`application/json`) or an SSE stream
    # (`text/event-stream`); both are folded into the line-based `Transport`
    # interface so `JsonRpcClient` works unchanged.
    #
    # Session management: the server may return an `Mcp-Session-Id` header in
    # the `initialize` response. We store and replay it on every subsequent
    # request. Bearer authentication is applied from the env var named by
    # `token_env`.
    class HttpTransport < Transport
      @response_lines = Channel(String).new
      @session_id : String? = nil
      @closed = false
      @extra_headers : Hash(String, String)

      def initialize(config : McpServerConfig, override_token : String? = nil)
        @url = config.url || ""
        @token = override_token || resolve_token(config)
        @extra_headers = config.headers
      end

      # For tests: inject a canned (url, token) pair directly.
      def initialize(@url : String, @token : String?)
        @extra_headers = {} of String => String
      end

      def write_line(json : String) : Nil
        return if @closed
        headers = build_headers
        response = post(json, headers)

        # Capture / refresh the session id.
        if sid = response.headers["Mcp-Session-Id"]?
          @session_id = sid
        end

        body = response.body || ""
        content_type = (response.headers["Content-Type"]? || "").downcase

        if content_type.includes?("text/event-stream")
          parse_sse(body).each { |data| @response_lines.send(data) }
        elsif content_type.includes?("application/json") && !body.empty?
          @response_lines.send(body)
        end
        # 202 Accepted with no body (typical for notifications): buffer
        # nothing — the reader fiber keeps blocking on `receive?`.
      end

      def read_line? : String?
        @response_lines.receive?
      end

      def close : Nil
        return if @closed
        @closed = true
        @response_lines.close
      end

      def closed? : Bool
        @closed
      end

      private def build_headers : HTTP::Headers
        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json, text/event-stream"
        headers["Authorization"] = "Bearer #{@token}" if @token
        if sid = @session_id
          headers["MCP-Session-Id"] = sid
        end
        @extra_headers.each { |k, v| headers[k] = v }
        headers
      end

      private def post(body : String, headers : HTTP::Headers) : HTTP::Client::Response
        uri = URI.parse(@url)
        client = make_client(uri)
        begin
          resp = client.post(uri.request_target, headers: headers, body: body)
          unless resp.success?
            raise RpcError.new(resp.status_code.to_i, "HTTP", "MCP HTTP #{resp.status_code}: #{resp.body.to_s[0...500]}")
          end
          resp
        ensure
          client.close
        end
      end

      # Build an `HTTP::Client`, honouring HTTPS_PROXY / HTTP_PROXY / ALL_PROXY
      # from the environment — mirrors `OpenAiChatProvider#make_client`.
      private def make_client(uri : URI) : HTTP::Client
        proxy = ENV["HTTPS_PROXY"]? || ENV["HTTP_PROXY"]? || ENV["ALL_PROXY"]?
        if (p = proxy) && !p.empty? && !bypass_proxy?(uri)
          return proxy_client(uri, p)
        end
        HTTP::Client.new(uri)
      end

      private def bypass_proxy?(uri : URI) : Bool
        host = uri.host || ""
        loopback = {"localhost", "127.0.0.1", "::1"}
        return true if loopback.includes?(host)
        no_proxy = ENV["NO_PROXY"]? || ENV["no_proxy"]?
        if np = no_proxy
          np.split(',').each do |entry|
            entry = entry.strip
            next if entry.empty?
            return true if host == entry || host.ends_with?(".#{entry.lstrip('.')}")
          end
        end
        false
      end

      private def proxy_client(target : URI, proxy_url : String) : HTTP::Client
        proxy = URI.parse(proxy_url)
        proxy_host = proxy.host || "127.0.0.1"
        proxy_port = proxy.port || 8080

        if target.scheme == "https"
          target_host = target.host || "localhost"
          target_port = target.port || 443
          socket = TCPSocket.new(proxy_host, proxy_port)
          socket << "CONNECT #{target_host}:#{target_port} HTTP/1.1\r\nHost: #{target_host}:#{target_port}\r\n\r\n"
          socket.flush
          status_line = socket.gets || ""
          unless status_line.includes?(" 200 ")
            socket.close
            raise "Proxy CONNECT failed: #{status_line.strip}"
          end
          while line = socket.gets
            break if line.strip.empty?
          end
          context = OpenSSL::SSL::Context::Client.new
          context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
          tls = OpenSSL::SSL::Socket::Client.new(socket, context: context, sync_close: true, hostname: target_host)
          HTTP::Client.new(tls, host: target_host, port: target_port)
        else
          HTTP::Client.new(proxy_host, proxy_port)
        end
      end

      # Read the bearer token from the env var named by `token_env`. Falls
      # back to a convention-based `MCP_<NAME>_TOKEN` lookup.
      private def resolve_token(config : McpServerConfig) : String?
        if env_name = config.token_env
          return ENV[env_name]?
        end
        key = "MCP_#{config.name.upcase.gsub(/[^A-Z0-9]/, "_")}_TOKEN"
        ENV[key]?
      end

      # Parse a `text/event-stream` body into a list of `data:` payloads.
      # SSE events are separated by blank lines; within an event, consecutive
      # `data:` lines are joined with `\n` (per the SSE spec). Lines that are
      # not `data:` (comments, `event:`, `id:`, etc.) are ignored.
      def parse_sse(body : String) : Array(String)
        events = [] of String
        data_lines = [] of String

        body.each_line do |raw|
          line = raw.rstrip('\r')
          if line.empty?
            unless data_lines.empty?
              events << data_lines.join('\n')
              data_lines.clear
            end
          elsif line.starts_with?("data:")
            data_lines << line[5..].lstrip
          elsif line.starts_with?("data: ")
            data_lines << line[6..]
          end
        end
        unless data_lines.empty?
          events << data_lines.join('\n')
        end
        events
      end
    end
  end
end
