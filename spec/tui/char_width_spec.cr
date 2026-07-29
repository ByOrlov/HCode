require "../spec_helper"

# Verify the layered width-calculation architecture mirrors the TS pipeline in
# `packages/pi-tui/src/utils.ts` (visibleWidth / asciiVisibleWidth /
# truncateToWidth / sliceWithWidth / extractAnsiCode).
describe Hcode::TUI::CharWidth do
  describe ".visible_width (codepoint_width layers)" do
    it "measures ASCII as 1 per char" do
      Hcode::TUI::CharWidth.visible_width("hello").should eq(5)
    end

    it "takes the printable-ASCII fast path (spaces ok)" do
      Hcode::TUI::CharWidth.visible_width("a b c").should eq(5)
    end

    it "counts default-emoji-presentation glyphs as width 2" do
      Hcode::TUI::CharWidth.visible_width("ok \u274C").should eq(5) # 2 + 1 + 2
      Hcode::TUI::CharWidth.visible_width("\u2705").should eq(2)    # ✅
      Hcode::TUI::CharWidth.visible_width("\u26A1").should eq(2)    # ⚡ emoji-default
    end

    it "treats text-default emoji glyphs as width 1 without VS16" do
      # ⚠ (U+26A0) defaults to TEXT presentation in terminals -> width 1.
      # Mirrors the `\p{RGI_Emoji}` gate in TS `graphemeWidth`: a bare
      # codepoint is width 2 only with Emoji_Presentation=Yes. Regression for
      # the table-alignment bug where the ⚠ row's right border drifted left.
      Hcode::TUI::CharWidth.visible_width("\u26A0").should eq(1) # ⚠ bare (text)
    end

    it "promotes a text-default glyph to width 2 with VS16 selector" do
      Hcode::TUI::CharWidth.visible_width("\u26A0\uFE0F").should eq(2) # ⚠️
    end

    it "counts CJK as width 2" do
      Hcode::TUI::CharWidth.visible_width("\u4f60\u597d").should eq(4) # 你好
    end

    it "counts fullwidth forms as width 2" do
      Hcode::TUI::CharWidth.visible_width("\uFF21").should eq(2) # Ａ
    end

    it "counts combining marks as width 0" do
      # e (1) + combining acute (0) = 1
      Hcode::TUI::CharWidth.visible_width("e\u0301").should eq(1)
    end

    it "treats a ZWJ emoji sequence as a single width-2 cluster" do
      # family: U+1F468 ZWJ U+1F469  -> one cluster, width 2
      Hcode::TUI::CharWidth.visible_width("\u{1F468}\u200D\u{1F469}").should eq(2)
    end

    it "counts a regional-indicator pair (flag) as width 2" do
      # 🇯🇵 = JP flag
      Hcode::TUI::CharWidth.visible_width("\u{1F1EF}\u{1F1F5}").should eq(2)
    end

    it "ignores ANSI SGR escapes" do
      Hcode::TUI::CharWidth.visible_width("\e[1mbold\e[0m").should eq(4)
    end

    it "ignores OSC 8 hyperlink escapes" do
      line = "\e]8;;https://example.test\e\\text\e]8;;\e\\"
      Hcode::TUI::CharWidth.visible_width(line).should eq(4)
    end

    it "expands tabs to 3 columns" do
      Hcode::TUI::CharWidth.visible_width("a\tb").should eq(5) # 1 + 3 + 1
    end

    it "returns 0 for empty string" do
      Hcode::TUI::CharWidth.visible_width("").should eq(0)
    end
  end

  describe ".visible_width cache" do
    it "returns consistent results across calls" do
      Hcode::TUI::CharWidth.clear_cache
      # ❌(2) space(1) 你好(4) space(1) ✅(2) = 10
      s = "\u274C \u4f60\u597d \u2705"
      first = Hcode::TUI::CharWidth.visible_width(s)
      second = Hcode::TUI::CharWidth.visible_width(s)
      second.should eq(first)
      first.should eq(10)
    end
  end

  describe ".ascii_visible_width" do
    it "returns width for plain ASCII" do
      Hcode::TUI::CharWidth.ascii_visible_width("hello", 100).should eq(5)
    end

    it "skips ANSI escapes" do
      Hcode::TUI::CharWidth.ascii_visible_width("\e[1mhi\e[0m", 100).should eq(2)
    end

    it "returns nil for non-ASCII content" do
      Hcode::TUI::CharWidth.ascii_visible_width("café", 100).should be_nil
    end

    it "returns nil for control characters" do
      Hcode::TUI::CharWidth.ascii_visible_width("a\tb", 100).should be_nil
    end

    it "early-exits past the limit" do
      val = Hcode::TUI::CharWidth.ascii_visible_width("abcdefgh", 3)
      val.should eq(4) # exceeds limit of 3 -> returns partial count
    end
  end

  describe ".extract_ansi_code" do
    it "extracts a CSI SGR sequence" do
      ansi = Hcode::TUI::CharWidth.extract_ansi_code("\e[1;31mtext", 0)
      ansi.should_not be_nil
      ansi.not_nil!.code.should eq("\e[1;31m")
      ansi.not_nil!.length.should eq(7)
    end

    it "extracts an OSC sequence terminated by ST" do
      ansi = Hcode::TUI::CharWidth.extract_ansi_code("\e]8;;url\e\\x", 0)
      ansi.should_not be_nil
      ansi.not_nil!.code.should eq("\e]8;;url\e\\")
      ansi.not_nil!.length.should eq(10)
    end

    it "extracts an OSC sequence terminated by BEL" do
      ansi = Hcode::TUI::CharWidth.extract_ansi_code("\e]0;title\u0007x", 0)
      ansi.should_not be_nil
      ansi.not_nil!.code.should eq("\e]0;title\u0007")
    end

    it "returns nil at a non-escape position" do
      Hcode::TUI::CharWidth.extract_ansi_code("plain", 0).should be_nil
    end
  end

  describe ".truncate_to_width" do
    it "keeps text shorter than the limit" do
      Hcode::TUI::CharWidth.truncate_to_width("hi", 10).should eq("hi")
    end

    it "pads short text when pad is true" do
      Hcode::TUI::CharWidth.truncate_to_width("hi", 5, pad: true).should eq("hi   ")
    end

    it "truncates with ellipsis" do
      result = Hcode::TUI::CharWidth.truncate_to_width("hello world", 8)
      result.should contain("...")
      Hcode::TUI::CharWidth.visible_width(result).should be <= 8
    end

    it "truncates wide-char text by display width" do
      # 4 CJK chars = width 8; truncate to width 6 -> keep 2 chars (4) + ellipsis (3) = 7
      result = Hcode::TUI::CharWidth.truncate_to_width("\u4f60\u4eec\u597d\u5417", 6)
      Hcode::TUI::CharWidth.visible_width(result).should be <= 6
      result.should contain("...")
    end
  end

  describe ".slice_with_width" do
    it "slices an ASCII range" do
      r = Hcode::TUI::CharWidth.slice_with_width("abcdef", 1, 3)
      r.text.should eq("bcd")
      r.width.should eq(3)
    end

    it "counts width correctly across wide chars" do
      # "a你好b": cols a(1) 你(2) 好(2) b(1). Slice cols [1,4) -> 你好 (width 4)
      r = Hcode::TUI::CharWidth.slice_with_width("a\u4f60\u597db", 1, 4)
      r.text.should eq("\u4f60\u597d")
      r.width.should eq(4)
    end

    it "returns empty for non-positive length" do
      r = Hcode::TUI::CharWidth.slice_with_width("abc", 0, 0)
      r.text.should eq("")
      r.width.should eq(0)
    end
  end

  describe "classification predicates" do
    it "detects emoji codepoints" do
      Hcode::TUI::CharWidth.could_be_emoji?(0x274C_u32).should be_true  # ❌
      Hcode::TUI::CharWidth.could_be_emoji?(0x0041_u32).should be_false # A
    end

    it "detects zero-width codepoints" do
      Hcode::TUI::CharWidth.zero_width?(0x0301_u32).should be_true # combining acute
      Hcode::TUI::CharWidth.zero_width?(0xFE0F_u32).should be_true # VS16
      Hcode::TUI::CharWidth.zero_width?(0x0041_u32).should be_false
    end

    it "detects CJK for word-breaking" do
      Hcode::TUI::CharWidth.cjk_break?(0x4F60_u32).should be_true # 你
      Hcode::TUI::CharWidth.cjk_break?(0x0041_u32).should be_false
    end
  end

  describe ".slice_into_width_chunks" do
    it "returns the whole string as a single chunk when it fits" do
      chunks = Hcode::TUI::CharWidth.slice_into_width_chunks("hello", 10)
      chunks.should eq(["hello"])
    end

    it "hard-breaks a wide CJK string into column-width chunks" do
      # 6 CJK chars = width 12; max_width 4 -> 3 chunks of width 4 (2 chars each)
      chunks = Hcode::TUI::CharWidth.slice_into_width_chunks("\u4f60\u4eec\u597d\u5417\u5927\u5bb6", 4)
      chunks.size.should eq(3)
      chunks.each { |c| Hcode::TUI::CharWidth.visible_width(c).should be <= 4 }
    end

    it "handles ASCII longer than max_width" do
      chunks = Hcode::TUI::CharWidth.slice_into_width_chunks("abcdefghij", 4)
      chunks.size.should eq(3)
      chunks[0].should eq("abcd")
      chunks[1].should eq("efgh")
      chunks[2].should eq("ij")
    end
  end

  describe ".visible_width cache eviction" do
    it "does not grow beyond WIDTH_CACHE_SIZE" do
      Hcode::TUI::CharWidth.clear_cache
      # Insert well over the limit; the soft-clear eviction must keep the
      # cache bounded instead of growing unboundedly.
      (0..5000).each { |i| Hcode::TUI::CharWidth.visible_width("k#{i}") }
      Hcode::TUI::CharWidth.cache_count.should be <= Hcode::TUI::CharWidth::WIDTH_CACHE_SIZE
      Hcode::TUI::CharWidth.clear_cache
    end
  end
end
