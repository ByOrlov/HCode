module Hcode
  module Mcp
    # MCP tool-call result → ToolResult output pipeline.
    #
    # Mirrors JS `output.ts`:
    # 1. Wrap media-only outputs in `<mcp_tool_result name="…">` tags so the
    #    model can attribute binary output.
    # 2. Apply the 100K text character budget.
    # 3. Apply the per-part 10 MB binary cap.
    module Output
      MAX_OUTPUT_CHARS       = 100_000
      MAX_BINARY_PART_BYTES  = 10 * 1024 * 1024
      # base64 length = ceil(bytes * 4 / 3)
      MAX_BINARY_PART_CHARS  = (MAX_BINARY_PART_BYTES * 4 / 3).to_i

      TRUNCATED_TEXT = "\n\n[Output truncated: exceeded #{MAX_OUTPUT_CHARS} character limit. " \
                       "Use pagination or more specific queries to get remaining content.]"

      # Post-process the decoded MCP result text. If the result is media-only
      # (data URIs with no accompanying text), wrap it so the model can
      # attribute the binary content. Truncate oversized text and drop
      # oversized binary parts.
      def self.post_process(text : String, qualified_tool_name : String) : String
        # Detect media-only: has data URIs but no real text content.
        has_media = text.includes?("data:")
        has_non_media_text = text.lines.any? do |l|
          !l.empty? && !l.starts_with?("data:")
        end

        if has_media && !has_non_media_text
          text = "<mcp_tool_result name=\"#{qualified_tool_name}\">\n#{text}\n</mcp_tool_result>"
        end

        # Apply per-line binary cap FIRST (before text budget truncation),
        # so an oversized data URI is dropped rather than truncated.
        text = text.lines.map do |line|
          if line.starts_with?("data:") && line.size > MAX_BINARY_PART_CHARS
            approx_mb = (line.size * 3 / 4 / (1024 * 1024)).to_i
            cap_mb = MAX_BINARY_PART_BYTES / (1024 * 1024)
            "[binary dropped: ~#{approx_mb} MB exceeds #{cap_mb} MB per-part limit. " \
            "Try a smaller resource.]"
          else
            line
          end
        end.join('\n')

        # Apply text budget.
        if text.size > MAX_OUTPUT_CHARS
          text = text[0...MAX_OUTPUT_CHARS] + TRUNCATED_TEXT
        end

        text
      end
    end
  end
end
