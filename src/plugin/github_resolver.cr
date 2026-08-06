require "http/client"
require "uri"
require "./source"
require "./types"

module Hcode
  module Plugin
    struct GithubResolution
      property tarball_url : String
      property display_version : String
      property ref : PluginGithubRef?

      def initialize(@tarball_url : String, @display_version : String, @ref : PluginGithubRef? = nil)
      end
    end

    module GithubResolver
      CODELOAD_BASE = "https://codeload.github.com"

      def self.resolve(source : GithubSource) : GithubResolution
        if ref = source.ref
          tarball = codeload_url(source.owner, source.repo, ref)
          return GithubResolution.new(tarball, ref.value, ref)
        end

        tag = try_resolve_latest_release_tag(source.owner, source.repo)
        if tag
          ref = PluginGithubRef.new("tag", tag)
          tarball = codeload_url(source.owner, source.repo, ref)
          return GithubResolution.new(tarball, tag, ref)
        end

        head_url = "#{CODELOAD_BASE}/#{source.owner}/#{source.repo}/zip/HEAD"
        head_ref = PluginGithubRef.new("branch", "HEAD")
        GithubResolution.new(head_url, "HEAD", head_ref)
      end

      private def self.try_resolve_latest_release_tag(owner : String, repo : String) : String?
        client = HTTP::Client.new(URI.parse("https://github.com"))
        client.connect_timeout = 15.seconds
        client.read_timeout = 15.seconds

        response = client.get("/#{owner}/#{repo}/releases/latest")

        case response.status_code
        when 404
          nil
        when 301, 302
          location = response.headers["Location"]?
          return nil unless location

          tag_match = location.match(/\/releases\/tag\/([^\/]+)$/)
          return nil unless tag_match

          tag = URI.decode_www_form(tag_match[1])
          tag.empty? || tag == "/releases" ? nil : tag
        else
          if response.status.success?
            nil
          else
            raise "Failed to resolve latest release for #{owner}/#{repo}: HTTP #{response.status_code}"
          end
        end
      end

      private def self.codeload_url(owner : String, repo : String, ref : PluginGithubRef) : String
        base = "#{CODELOAD_BASE}/#{owner}/#{repo}/zip"
        encoded = encode_ref_path(ref.value)

        case ref.kind
        when "sha"
          "#{base}/#{encoded}"
        when "tag"
          "#{base}/refs/tags/#{encoded}"
        when "branch"
          "#{base}/#{encoded}"
        else
          "#{base}/#{encoded}"
        end
      end

      private def self.encode_ref_path(value : String) : String
        value.split('/').map { |seg| URI.encode_www_form(seg) }.join('/')
      end
    end
  end
end
