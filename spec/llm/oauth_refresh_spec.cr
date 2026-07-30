require "../spec_helper"
require "../support/mock_http_transport"

describe Hcode::LLM::OAuthCredentials do
  describe "#refresh!" do
    it "refreshes tokens via the transport on a 200 response" do
      creds = Hcode::LLM::OAuthCredentials.new(
        access_token: "old-access",
        refresh_token: "rt",
        expires_at: 1_i64,
      )

      transport = Hcode::MockHttpTransport.new
      transport.response_status = 200
      transport.response_body = %({
        "access_token": "new-access",
        "refresh_token": "new-rt",
        "expires_in": 600,
        "token_type": "Bearer"
      })

      creds.refresh!("https://auth.example.com", "client-id", transport)
      creds.bearer_token.should eq("new-access")
      creds.expires_in.should eq(600)
      transport.last_uri.not_nil!.to_s.should contain("/api/oauth/token")
      (transport.last_body || "").should contain("refresh_token=rt")
    end

    it "raises on non-200 status" do
      creds = Hcode::LLM::OAuthCredentials.new(
        access_token: "a",
        refresh_token: "rt",
        expires_at: 1_i64,
      )

      transport = Hcode::MockHttpTransport.new
      transport.response_status = 401
      transport.response_body = "invalid_grant"

      error = expect_raises(Exception) do
        creds.refresh!("https://auth.example.com", "client-id", transport)
      end
      (error.message || "").should contain("401")
    end

    it "surfaces IO::Error (network drop) from transport" do
      creds = Hcode::LLM::OAuthCredentials.new(
        access_token: "a",
        refresh_token: "rt",
        expires_at: 1_i64,
      )

      transport = Hcode::MockHttpTransport.new
      transport.request_error = IO::Error.new("Connection refused")

      error = expect_raises(IO::Error) do
        creds.refresh!("https://auth.example.com", "client-id", transport)
      end
      (error.message || "").should contain("Connection refused")
    end
  end
end
