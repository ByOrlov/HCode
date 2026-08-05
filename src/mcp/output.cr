require "base64"
require "../tools/read_media"

module Hcode
  module Mcp
    # MCP tool-call result → ToolResult output pipeline.
    #
    # Mirrors JS `output.ts`:
    # 1. Wrap media-only outputs in `<mcp_tool_result name="…">` tags so the
    #    model can attribute binary output.
    # 2. Apply the 100K text character budget.
    # 3. Apply the per-part 10 MB binary cap.
    # 4. Compress oversized inline images via the same `ImageProcessor`
    #    pipeline `ReadMediaFile` uses, so a screenshot is downsampled and
    #    kept rather than dropped to a text notice.
    module Output
      MAX_OUTPUT_CHARS      = 100_000
      MAX_BINARY_PART_BYTES = 10 * 1024 * 1024
      # base64 length = ceil(bytes * 4 / 3)
      MAX_BINARY_PART_CHARS = (MAX_BINARY_PART_BYTES * 4 / 3).to_i

      TRUNCATED_TEXT = "\n\n[Output truncated: exceeded #{MAX_OUTPUT_CHARS} character limit. " \
                       "Use pagination or more specific queries to get remaining content.]"

      # Post-process the decoded MCP result text. If the result is media-only
      # (data URIs with no accompanying text), wrap it so the model can
      # attribute the binary content. Compress oversized images, truncate
      # oversized text, and drop oversized binary parts.
      #
      # Returns a named tuple `{text, truncated}` so callers can propagate the
      # `truncated` flag onto `ToolResult`.
      def self.post_process(text : String, qualified_tool_name : String) : {text: String, truncated: Bool}
        # Detect media-only: has data URIs but no real text content.
        has_media = text.includes?("data:")
        has_non_media_text = text.lines.any? do |l|
          !l.empty? && !l.starts_with?("data:")
        end

        if has_media && !has_non_media_text
          text = "<mcp_tool_result name=\"#{qualified_tool_name}\">\n#{text}\n</mcp_tool_result>"
        end

        # Compress oversized inline images BEFORE the binary cap, so a large
        # but compressible screenshot is downsampled and kept rather than
        # dropped to a text notice. Mirrors JS `compressImageContentParts`.
        text = compress_image_lines(text)

        # Apply per-line binary cap (after compression, so only truly
        # incompressible oversized parts are dropped).
        truncated = false
        text = text.lines.map do |line|
          if line.starts_with?("data:") && line.size > MAX_BINARY_PART_CHARS
            truncated = true
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
          truncated = true
        end

        {text: text, truncated: truncated}
      end

      # Walk each line; for `data:image/...;base64,...` URIs, decode → compress
      # via the shared ImageProcessor → re-encode. Non-image data URIs and
      # text lines pass through untouched.
      private def self.compress_image_lines(text : String) : String
        text.lines.map do |line|
          next line unless line.starts_with?("data:image/")
          compress_one_image_line(line)
        end.join('\n')
      end

      private def self.compress_one_image_line(line : String) : String
        # Parse `data:<mime>;base64,<payload>`
        comma_idx = line.index(',')
        return line unless comma_idx
        header = line[0...comma_idx]
        payload = line[(comma_idx + 1)..]

        # Extract mime type.
        mime = header[5..]? || "image/png"
        semi = mime.index(';')
        mime = mime[0...semi] if semi

        # Decode base64 → bytes.
        bytes = begin
          Base64.decode(payload)
        rescue
          return line
        end

        # Skip tiny images — already under budget.
        if bytes.size <= Tools::Media::IMAGE_BYTE_BUDGET
          return line
        end

        # Compress via the shared processor (defaults to pass-through when no
        # real image library is wired, e.g. PassThroughImageProcessor).
        processor = Tools::Media.image_processor || Tools::PassThroughImageProcessor.new
        outcome = processor.compress(
          bytes, mime,
          byte_budget: Tools::Media::IMAGE_BYTE_BUDGET,
          max_edge: Tools::Media::MAX_IMAGE_EDGE_PX,
        )

        # If the processor couldn't shrink it, leave the original.
        return line if outcome.data.size >= bytes.size

        re_encoded = "data:#{outcome.mime_type};base64,#{Base64.strict_encode(outcome.data)}"
        caption = if outcome.resized?
                    original_kb = (bytes.size / 1024.0).round
                    final_kb = (outcome.data.size / 1024.0).round
                    "[image compressed: #{outcome.original_width}x#{outcome.original_height} " \
                    "(#{original_kb} KB) → #{outcome.width}x#{outcome.height} " \
                    "(#{final_kb} KB)]"
                  else
                    ""
                  end
        caption.empty? ? re_encoded : "#{re_encoded}\n#{caption}"
      rescue
        # Any failure in the compression path: return the original line so the
        # image is never silently lost.
        line
      end
    end
  end
end
