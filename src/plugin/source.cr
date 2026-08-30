require "uri"

module H2code
  module Plugin
    struct GithubSource
      property owner : String
      property repo : String
      property ref : PluginGithubRef?

      def initialize(@owner : String, @repo : String, @ref : PluginGithubRef? = nil)
      end
    end

    enum ResolvedSourceKind
      LocalPath
      ZipUrl
      Github
    end

    struct ResolvedSource
      property kind : ResolvedSourceKind
      property path : String?         # local-path or zip-url
      property github : GithubSource? # github

      def initialize(@kind : ResolvedSourceKind, @path : String? = nil, @github : GithubSource? = nil)
      end
    end

    module SourceResolver
      def self.resolve(source : String) : ResolvedSource
        trimmed = source.strip

        gh = parse_github_url(trimmed)
        return ResolvedSource.new(ResolvedSourceKind::Github, github: gh) if gh

        if trimmed.starts_with?("http://") || trimmed.starts_with?("https://")
          return ResolvedSource.new(ResolvedSourceKind::ZipUrl, path: trimmed)
        end

        unless Path.new(trimmed).absolute?
          raise "Plugin root must be an absolute path (got \"#{trimmed}\")"
        end

        ResolvedSource.new(ResolvedSourceKind::LocalPath, path: trimmed)
      end

      def self.parse_github_url(raw : String) : GithubSource?
        uri = URI.parse(raw)
        return nil unless uri.scheme == "https"
        host = uri.host || ""
        return nil unless host == "github.com" || host == "www.github.com"

        segments = uri.path.split('/').reject(&.empty?)
        return nil unless segments.size >= 2

        owner = segments[0]
        repo = segments[1].rchop(".git")
        rest = segments[2..]

        return GithubSource.new(owner, repo) if rest.empty?

        case rest[0]
        when "tree"
          return nil unless rest.size >= 2
          ref_value = decode_ref_segments(rest[1..])
          kind = ref_value.matches?(/^[0-9a-f]{7,40}$/) ? "sha" : "branch"
          GithubSource.new(owner, repo, PluginGithubRef.new(kind, ref_value))
        when "releases"
          return nil unless rest.size >= 3 && rest[1] == "tag"
          ref_value = decode_ref_segments(rest[2..])
          GithubSource.new(owner, repo, PluginGithubRef.new("tag", ref_value))
        when "commit"
          return nil unless rest.size >= 2
          sha = decode_ref_segments(rest[1..])
          GithubSource.new(owner, repo, PluginGithubRef.new("sha", sha))
        else
          nil
        end
      rescue
        nil
      end

      private def self.decode_ref_segments(segments : Array(String)) : String
        segments.map { |s| URI.decode_www_form(s) }.join('/')
      end
    end
  end
end
