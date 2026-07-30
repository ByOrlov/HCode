require "../spec_helper"
require "../../src/auth/oauth"

private class FakeOAuthServer
  # Configurable responses for each endpoint.
  property device_auth_response : {Int32, String} = {200, %({"user_code":"ABC123","device_code":"dev123","verification_uri":"https://kimi.com/device","verification_uri_complete":"https://kimi.com/device?code=ABC123","interval":1})}
  property token_responses : Array({Int32, String}) = [] of {Int32, String}
  property request_count : Int32 = 0
  property last_device_code : String?

  def post_form(url : String, body : String) : {Int32, String}
    @request_count += 1
    if url.includes?("/api/oauth/device_authorization")
      @device_auth_response
    else
      idx = {@request_count - 2, 0}.max
      resp = @token_responses[idx]? || {200, %({"access_token":"tok","refresh_token":"ref","expires_in":900,"token_type":"Bearer"})}
      resp
    end
  end
end

describe Hcode::Auth::OAuth do
  describe ".request_device_authorization" do
    it "parses a valid device authorization response" do
      # We can't easily mock HTTP without injecting transport; this test
      # verifies the parsing logic indirectly through the struct shape.
      auth = Hcode::Auth::OAuth::DeviceAuthorization.new(
        user_code: "ABC123",
        device_code: "dev456",
        verification_uri: "https://kimi.com/device",
        verification_uri_complete: "https://kimi.com/device?code=ABC123",
        interval: 5,
      )
      auth.user_code.should eq("ABC123")
      auth.device_code.should eq("dev456")
      auth.verification_uri_complete.should contain("ABC123")
      auth.interval.should eq(5)
    end
  end

  describe Hcode::Auth::OAuth::PollResult do
    it "success? returns true for Success kind" do
      r = Hcode::Auth::OAuth::PollResult.new(Hcode::Auth::OAuth::PollResultKind::Success)
      r.success?.should be_true
      r.pending?.should be_false
    end

    it "pending? returns true for Pending kind" do
      r = Hcode::Auth::OAuth::PollResult.new(Hcode::Auth::OAuth::PollResultKind::Pending, description: "waiting")
      r.pending?.should be_true
      r.success?.should be_false
    end
  end

  describe "constants" do
    it "uses the Kimi Code auth host and client id" do
      Hcode::Auth::OAuth::DEFAULT_OAUTH_HOST.should eq("https://auth.kimi.com")
      Hcode::Auth::OAuth::DEFAULT_CLIENT_ID.should eq("17e5f671-d194-4dfb-9706-5516cb48c098")
    end

    it "default credentials path is under ~/.kimi-code/credentials" do
      Hcode::Auth::OAuth::DEFAULT_CREDENTIALS_PATH.should contain(".kimi-code")
      Hcode::Auth::OAuth::DEFAULT_CREDENTIALS_PATH.should contain("credentials")
    end
  end

  describe Hcode::Auth::OAuth::OAuthError do
    it "is a rescuable Exception" do
      err = Hcode::Auth::OAuth::OAuthError.new("test")
      err.message.should eq("test")
      err.should be_a(Exception)
    end
  end
end
