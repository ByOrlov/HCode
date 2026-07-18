module Kimi
  module Tools
    # Sensitive-file detection.
    #
    # Ported from `packages/agent-core/src/tools/policies/sensitive.ts`.
    # Files matching any of these patterns are filtered out of Glob/Grep
    # results so credentials cannot be exfiltrated through a compromised
    # prompt. Exemptions like `.env.example` are explicitly allowed.
    module Sensitive
      SENSITIVE_BASENAMES = Set{
        ".env",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        "credentials",
      }

      SENSITIVE_PATH_SUFFIXES = [
        {".aws", "credentials"},
        {".gcp", "credentials"},
      ]

      ENV_PREFIX           = ".env."
      ENV_EXEMPTIONS       = Set{".env.example", ".env.sample", ".env.template"}
      BASENAME_PREFIXES    = ["id_rsa", "id_ed25519", "id_ecdsa", "credentials"]
      PUBLIC_KEY_BASENAMES = Set{"id_rsa.pub", "id_ed25519.pub", "id_ecdsa.pub"}

      DOT_VARIANT_SUFFIXES = Set{
        ".bak", ".backup", ".copy", ".disabled", ".key",
        ".old", ".orig", ".pem", ".save", ".tmp",
      }

      # VCS metadata directories always skipped by Glob/Grep (never listed,
      # even when `include_ignored` is set). Mirrors
      # `VCS_DIRECTORIES_TO_EXCLUDE` in `support/run-rg.ts`.
      VCS_DIRECTORIES_TO_EXCLUDE = [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"]

      KEY_BASENAMES = ["id_rsa", "id_ed25519", "id_ecdsa"]

      # Conservative prefilter globs passed to rg via `--glob !...`.
      # Mirrors `SENSITIVE_GLOBS_TO_EXCLUDE` in `support/run-rg.ts`. The
      # authoritative check still runs on parsed records via `sensitive?`.
      #
      # Cached at first call — `build_globs_to_exclude` is private and pure.
      @@globs_to_exclude : Array(String)?

      def self.globs_to_exclude : Array(String)
        @@globs_to_exclude ||= build_globs_to_exclude
      end

      def self.build_globs_to_exclude : Array(String)
        globs = ["**/.env"]
        KEY_BASENAMES.each do |name|
          globs << "**/#{name}"
          globs << "**/#{name}[-_]*"
          DOT_VARIANT_SUFFIXES.each { |suffix| globs << "**/#{name}#{suffix}" }
        end
        globs.concat([
          "**/.aws/credentials", "**/.aws/credentials/**",
          "**/.gcp/credentials", "**/.gcp/credentials/**",
        ])
        globs
      end

      # Returns true if `path` matches a sensitive pattern. Case-insensitive
      # to catch e.g. `ID_RSA` and `Credentials` variants.
      def self.sensitive?(path : String) : Bool
        name = File.basename(path).downcase
        cmp_path = path.downcase

        return false if ENV_EXEMPTIONS.includes?(name)
        return false if PUBLIC_KEY_BASENAMES.includes?(name)
        return true if SENSITIVE_BASENAMES.includes?(name)
        return true if name.starts_with?(ENV_PREFIX)

        BASENAME_PREFIXES.each do |prefix|
          return true if name == prefix
          # Catch rename-shielded variants without flagging unrelated filenames
          # like `id_rsafoo` or ordinary JSON files like `credentials.json`.
          next unless name.size > prefix.size && name.starts_with?(prefix)
          suffix = name[prefix.size..]
          next_c = suffix[0]?
          return true if next_c == '-' || next_c == '_'
          return true if next_c == '.' && DOT_VARIANT_SUFFIXES.includes?(suffix)
        end

        SENSITIVE_PATH_SUFFIXES.each do |parts|
          suffix = "#{parts[0]}/#{parts[1]}"
          return true if cmp_path.ends_with?("/#{suffix}") || cmp_path.includes?("/#{suffix}/")
        end

        false
      end
    end
  end
end
