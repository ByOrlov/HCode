module Hcode
  module Tools
    # FetchURL — чтение публичного URL с извлечением текста.
    #
    # Контракт перенесён 1:1 из
    # `packages/agent-core-v2/src/app/web/tools/fetch-url.ts`.
    # HTTP-фечинг делегирован инжекченному `UrlFetcher` (по умолчанию —
    # `LocalFetcher` через HTTP::Client + упрощённый HTML-extract).
    #
    # См. детальный план портирования в `md-tools/fetch-url.md`.
    class FetchURL < Tool
      DEFAULT_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
      DEFAULT_MAX_BYTES  = 10 * 1024 * 1024
      MAX_CHARS          = 50_000
      TRUNCATION_MARKER  = "[...truncated]"
      TRUNCATION_MESSAGE = "Output is truncated to fit in the message."
      NOTE_PASSTHROUGH   = "The returned content is the full response body, returned verbatim."
      NOTE_EXTRACTED     = "The returned content is the main text extracted from the page."
      CITE_REMINDER      = "If you use it in your answer, cite this page as a markdown link, e.g. [title](url)."

      DESCRIPTION = <<-TEXT
        Fetch content from a URL. The content is returned either as the main text extracted from the page, or as the full response body verbatim; a note at the top of the result states which of the two you received, so you can judge how complete it is. Use this when you need to read a specific web page.

        Only fully-formed public `http`/`https` URLs are supported; other schemes and private or loopback addresses are not fetched. Very large pages may be truncated or refused. The fetch carries no login or session for the target site, so pages behind authentication (private repositories, internal dashboards) return a login page or an error instead of the real content — if the text you get back looks like a generic landing or sign-in page, treat that as the login wall, not the answer, and reach the content through a credentialed route (an authenticated CLI or MCP tool) instead.
      TEXT

      # Глобальный инжекченный сервис. По умолчанию — LocalWebFetchService.
      @@service : WebFetchService = LocalWebFetchService.new

      def self.service=(s : WebFetchService) : Nil
        @@service = s
      end

      def self.service : WebFetchService
        @@service
      end

      def name : String
        "FetchURL"
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "The URL to fetch content from."
            }
          },
          "required": ["url"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        url = input["url"]?.try(&.to_s) || ""
        if url.empty?
          return ToolResult.error("URL is required.")
        end

        fetcher = @@service.get_url_fetcher

        begin
          result = fetcher.fetch(url, nil, nil)
        rescue ex : HttpFetchError
          return ToolResult.error("Failed to fetch URL. Status: #{ex.status}. #{ex.message}")
        rescue ex
          return ToolResult.error("Failed to fetch URL due to network error: #{url}. #{ex.message || ex.to_s}")
        end

        format_success(url, result)
      end

      # ------------------------------------------------------------------
      # Рендер
      # ------------------------------------------------------------------

      def format_success(url : String, result : UrlFetchResult) : ToolResult
        if result.content.empty?
          return ToolResult.success("The response body is empty.")
        end

        note = result.kind.passthrough? ? NOTE_PASSTHROUGH : NOTE_EXTRACTED
        body = "#{note} #{CITE_REMINDER}\n\n#{result.content}"
        truncated, final = truncate_to_budget(body, MAX_CHARS)

        res = ToolResult.success(final)
        res.truncated = true if truncated
        res
      end

      def truncate_to_budget(text : String, max_chars : Int32) : {Bool, String}
        return {false, text} if text.size <= max_chars
        cut = max_chars - TRUNCATION_MARKER.size - TRUNCATION_MESSAGE.size - 2
        cut = 1 if cut < 1
        final = text[0, cut] + TRUNCATION_MARKER + ". " + TRUNCATION_MESSAGE
        {true, final}
      end
    end

    # --------------------------------------------------------------------
    # UrlFetcher contract
    # --------------------------------------------------------------------

    enum UrlFetchKind
      Passthrough
      Extracted

      def passthrough? : Bool
        self == Passthrough
      end

      def extracted? : Bool
        self == Extracted
      end
    end

    struct UrlFetchResult
      property content : String
      property kind : UrlFetchKind

      def initialize(@content : String, @kind : UrlFetchKind)
      end
    end

    class HttpFetchError < Exception
      property status : Int32

      def initialize(@status : Int32, message : String)
        super(message)
      end
    end

    abstract class UrlFetcher
      abstract def fetch(url : String,
                         tool_call_id : String? = nil,
                         signal : AbortController? = nil) : UrlFetchResult
    end

    abstract class WebFetchService
      abstract def get_url_fetcher : UrlFetcher
    end

    # Локальный fetcher: HTTP::Client + примитивный HTML-extract.
    # Не использует `@mozilla/readability` (нет в Crystal) — поэтому
    # результат менее чистый, но сохраняет основной контракт.
    class LocalFetcher < UrlFetcher
      private IPV4_PRIVATE_RANGES = [
        {127, 0, 0, 0, 8},   # 127.0.0.0/8 loopback
        {10, 0, 0, 0, 8},    # 10.0.0.0/8
        {192, 168, 0, 0, 16},# 192.168.0.0/16
        {172, 16, 0, 0, 12}, # 172.16.0.0/12
        {169, 254, 0, 0, 16},# 169.254.0.0/16 link-local
        {0, 0, 0, 0, 8},     # 0.0.0.0/8
        {100, 64, 0, 0, 10}, # 100.64.0.0/10 CGNAT
      ]

      @transport : HttpTransport

      def initialize(transport : HttpTransport? = nil)
        @transport = transport || HttpTransport::RealHttpTransport.new(->(uri : URI) { HTTP::Client.new(uri) })
      end

      def fetch(url : String,
                tool_call_id : String? = nil,
                signal : AbortController? = nil) : UrlFetchResult
        uri = parse_safe_target(url)

        headers = HTTP::Headers{
          "User-Agent"      => FetchURL::DEFAULT_USER_AGENT,
          "Accept"          => "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5",
          "Accept-Encoding" => "gzip",
        }

        status_code = 0
        content_type = ""
        body = String.build do |io|
          response = @transport.request("GET", uri, headers)
          status_code = response.status_code
          content_type = response.headers["Content-Type"]? || ""
          if response.status_code >= 400
            raise HttpFetchError.new(response.status_code, "HTTP #{response.status_code} #{response.status_message}")
          end
          io << response.body
        end

        bytesize = body.bytesize
        if bytesize > FetchURL::DEFAULT_MAX_BYTES
          raise HttpFetchError.new(0, "Response body too large: #{bytesize} bytes exceeds maxBytes (#{FetchURL::DEFAULT_MAX_BYTES}).")
        end

        extract_main_content(body, content_type.downcase)
      end

      # ------------------------------------------------------------------

      def parse_safe_target(url : String) : URI
        uri = URI.parse(url)
      rescue ex
        raise Exception.new("Invalid URL: \"#{url}\"")
      else
        scheme = uri.scheme.try(&.downcase)
        unless scheme == "http" || scheme == "https"
          raise Exception.new("Unsupported URL scheme \"#{scheme}\" — only http(s) allowed.")
        end

        host = uri.host.to_s.downcase
        host = host.lchop('[').rchop(']') # IPv6 literals
        if host.empty?
          raise Exception.new("Invalid URL: missing host.")
        end

        if host == "localhost" || host.ends_with?(".localhost")
          raise Exception.new("Refusing to fetch private host: \"#{host}\"")
        end

        # IPv6 special cases
        if host.includes?(':')
          case host
          when "::1", "::", "fe80::", "fc00::", "fd00::"
            raise Exception.new("Refusing to fetch private host: \"#{host}\"")
          end
        end

        # IPv4 literal checks
        if match = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
          octets = [match[1].to_i, match[2].to_i, match[3].to_i, match[4].to_i]
          if octets.any? { |o| o > 255 }
            raise Exception.new("Invalid IPv4 literal: \"#{host}\"")
          end
          if ipv4_private?(octets[0], octets[1], octets[2], octets[3])
            raise Exception.new("Refusing to fetch private address: \"#{host}\"")
          end
        end

        uri
      end

      private def ipv4_private?(o0 : Int32, o1 : Int32, o2 : Int32, o3 : Int32) : Bool
        IPV4_PRIVATE_RANGES.each do |base0, base1, base2, base3, prefix|
          in_range = case prefix
                     when 8  then o0 == base0
                     when 10 then o0 == base0 && (o1 & 0xC0) == (base1 & 0xC0)
                     when 12 then o0 == base0 && o1 >= base1 && o1 < base1 + 16
                     when 16 then o0 == base0 && o1 == base1
                     else          false
                     end
          return true if in_range
        end
        false
      end

      def extract_main_content(body : String, content_type : String) : UrlFetchResult
        if content_type.starts_with?("text/plain") || content_type.starts_with?("text/markdown")
          return UrlFetchResult.new(body, UrlFetchKind::Passthrough)
        end

        # Упрощённый HTML-extract.
        title = extract_title(body)
        text = strip_html_tags(body)
        if text.strip.empty?
          raise Exception.new("Failed to extract meaningful content from the page. The page may require JavaScript to render.")
        end
        content = title.empty? ? text : "# #{title}\n\n#{text}"
        UrlFetchResult.new(content, UrlFetchKind::Extracted)
      end

      # Извлечь <title>...</title> из HTML.
      private def extract_title(html : String) : String
        if match = html.match(/<title[^>]*>(.*?)<\/title>/imx)
          match[1].strip.gsub(/\s+/, " ")
        else
          ""
        end
      end

      # Удалить <script>/<style>/... и схлопнуть whitespace в основном body.
      private def strip_html_tags(html : String) : String
        s = html.dup

        # Выделить body (если есть), иначе весь документ.
        if match = s.match(/<body[^>]*>(.*)<\/body>/imx)
          s = match[1]
        end

        # Удалить script/style/noscript/template/head блоки.
        s = s.gsub(/<script\b[^>]*>.*?<\/script>/imx, "")
        s = s.gsub(/<style\b[^>]*>.*?<\/style>/imx, "")
        s = s.gsub(/<noscript\b[^>]*>.*?<\/noscript>/imx, "")
        s = s.gsub(/<template\b[^>]*>.*?<\/template>/imx, "")
        s = s.gsub(/<head\b[^>]*>.*?<\/head>/imx, "")

        # Блочные теги → newline.
        s = s.gsub(/<\/(p|div|section|article|h[1-6]|li|ul|ol|pre|blockquote|br|tr|table)\s*>/i, "\n")
        s = s.gsub(/<br\s*\/?>/i, "\n")

        # Удалить все остальные теги.
        s = s.gsub(/<[^>]+>/, "")

        # Декодировать базовые сущности.
        s = s.gsub("&nbsp;", " ")
        s = s.gsub("&amp;", "&")
        s = s.gsub("&lt;", "<")
        s = s.gsub("&gt;", ">")
        s = s.gsub("&quot;", "\"")
        s = s.gsub(/&#(\d+);/) { |_|
          # numeric entity (basic decode)
          ""
        }

        # Схлопнуть whitespace.
        s = s.gsub(/\r\n?/, "\n")
        s = s.gsub(/\t/, "  ")
        s = s.gsub(/[ ]+\n/, "\n")
        s = s.gsub(/\n{3,}/, "\n\n")
        s = s.gsub(/^[ \t]+/, "")
        s.strip
      end
    end

    class LocalWebFetchService < WebFetchService
      @fetcher : LocalFetcher

      def initialize(transport : HttpTransport? = nil)
        @fetcher = LocalFetcher.new(transport)
      end

      def get_url_fetcher : UrlFetcher
        @fetcher
      end
    end
  end
end
