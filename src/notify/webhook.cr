require "http/client"

module H2code
  module Notify
    # Webhook delivery channel. Fires a user-configured HTTP request on a
    # transition, running in a detached fiber with a configurable timeout.
    # Network errors are swallowed — a flaky endpoint must never break a turn.
    class Webhook
      @url : String
      @method : String
      @headers : Hash(String, String)
      @secret : String
      @timeout : Time::Span
      @transport : HttpTransport

      def initialize(@url : String,
                     method : String = "POST",
                     headers : Hash(String, String) = {} of String => String,
                     @secret : String = "",
                     timeout_ms : Int32 = 5000,
                     transport : HttpTransport? = nil)
        @method = method.upcase
        @headers = headers
        @timeout = timeout_ms.milliseconds
        @transport = transport || begin
          t = @timeout
          HttpTransport::RealHttpTransport.new(->(uri : URI) do
            c = HTTP::Client.new(uri)
            c.connect_timeout = t
            c.read_timeout = t
            c
          end)
        end
      end

      def fire(payload : Transition) : Nil
        return if @url.empty?
        spawn do
          begin
            body = Webhook.build_payload(payload)
            headers = HTTP::Headers{"Content-Type" => "application/json"}
            @headers.each { |k, v| headers[k] = v }
            headers["X-H2Code-Webhook-Secret"] = @secret unless @secret.empty?

            uri = URI.parse(@url)
            @transport.request(@method, uri, headers, body)
          rescue ex
            # Swallow — a flaky webhook must never break a turn.
          end
        end
      end

      def self.build_payload(payload : Transition) : String
        JSON.build do |json|
          json.object do
            json.field "event", payload.event
            json.field "status", payload.next_status.to_s.downcase
            json.field "prev_status", payload.prev_status.to_s.downcase
            json.field "title", payload.title
            json.field "body", payload.body
            json.field "session_id", payload.session_id
            json.field "timestamp", payload.timestamp
          end
        end
      end
    end
  end
end
