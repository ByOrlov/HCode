module Hcode
  module Mcp
    # Builds the proxy tool name exposed to the agent (`mcp__<server>__<tool>`)
    # and the inverse parse back to the remote tool name. Names are sanitized
    # to `[A-Za-z0-9_]` so they match the permission DSL (`mcp__github__*`)
    # and survive round-tripping through JSON tool-call arguments.
    module ToolNaming
      PREFIX     = "mcp__"
      MAX_LENGTH = 64

      # Compose the agent-facing name for a remote tool. Overlong names are
      # truncated and suffixed with a short FNV-1a hash so two distinct remote
      # tools never collapse to the same proxy name.
      def self.proxy_name(server : String, remote : String) : String
        s = sanitize(server)
        t = sanitize(remote)
        name = "#{PREFIX}#{s}__#{t}"
        return name if name.size <= MAX_LENGTH
        hash = fnv1a_hex(name)[0...8]
        # Leave room for the `__<hash>` tail.
        keep = MAX_LENGTH - hash.size - 2
        name[0...keep] + "__" + hash
      end

      # Split a proxy name back into its server + remote-tool components, or
      # nil when the name is not an MCP proxy name.
      def self.split(proxy : String) : {String, String}?
        return nil unless proxy.starts_with?(PREFIX)
        rest = proxy[PREFIX.size..]
        sep = rest.index("__")
        return nil unless sep
        {rest[0...sep], rest[(sep + 2)..]}
      end

      private def self.sanitize(part : String) : String
        cleaned = part.gsub(/[^A-Za-z0-9_]/, "_").gsub(/_+/, "_")
        cleaned.empty? ? "tool" : cleaned
      end

      # 32-bit FNV-1a, hex-encoded. Crystal's `String#hash` is not stable
      # across versions, so use the explicit algorithm.
      private def self.fnv1a_hex(str : String) : String
        hash = 2166136261_u32
        str.each_byte do |b|
          hash ^= b
          hash &*= 16777619_u32
        end
        hash.to_s(16)
      end
    end
  end
end
