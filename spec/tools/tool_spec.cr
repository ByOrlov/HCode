require "../spec_helper"

describe H2code::Tools::Tool do
  describe ".sanitize_output" do
    it "passes through clean UTF-8 unchanged" do
      cleaned = H2code::Tools::Tool.sanitize_output("hello world\nline two\n")
      cleaned.should eq("hello world\nline two\n")
    end

    it "replaces invalid UTF-8 bytes and appends a notice" do
      # ELF magic + stray continuation bytes, like `cat` on a binary.
      binary = String.new(Bytes[0x7F, 0x45, 0x4C, 0x46, 0xFF, 0xFE, 0x68, 0x69])
      cleaned = H2code::Tools::Tool.sanitize_output(binary)

      cleaned.valid_encoding?.should be_true
      cleaned.should contain(H2code::Tools::Tool::SANITIZE_NOTICE)
      cleaned.should contain("hi") # 0x68 0x69 survive as valid UTF-8
    end

    it "strips C0 control bytes (except tab/newline/cr) and appends a notice" do
      noisy = "a\x00b\x07c\x08d\te\nf\rg"
      cleaned = H2code::Tools::Tool.sanitize_output(noisy)

      cleaned.valid_encoding?.should be_true
      # Tab, newline, carriage return are preserved.
      cleaned.should contain("\t")
      cleaned.should contain("\n")
      cleaned.should contain("\r")
      # NUL / BEL / BS are gone (replaced by U+FFFD).
      cleaned.should_not contain("\x00")
      cleaned.should contain(H2code::Tools::Tool::SANITIZE_NOTICE)
    end

    it "produces valid UTF-8 that JSON-serializes without raising" do
      binary = String.new(Bytes[0x7F, 0x45, 0x4C, 0x46, 0xC0, 0xC1, 0x00, 0x1B, 0x68])
      cleaned = H2code::Tools::Tool.sanitize_output(binary)

      cleaned.valid_encoding?.should be_true
      # A round-trip through JSON::Builder must not raise — this is the exact
      # path that previously produced "Chat API error 400".
      json = String.build { |io| cleaned.to_json(io) }
      JSON.parse(json).as_s.should eq(cleaned)
    end
  end
end
