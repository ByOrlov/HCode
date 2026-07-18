require "../spec_helper"

describe Hcode::LLM::TokenCounter do
  describe ".format_count" do
    it "formats small counts as plain integers" do
      Hcode::LLM::TokenCounter.format_count(0).should eq("0")
      Hcode::LLM::TokenCounter.format_count(512).should eq("512")
      Hcode::LLM::TokenCounter.format_count(1023).should eq("1023")
    end

    it "formats kilo boundaries on 1024" do
      Hcode::LLM::TokenCounter.format_count(1024).should eq("1k")
      Hcode::LLM::TokenCounter.format_count(1536).should eq("1.5k")
      Hcode::LLM::TokenCounter.format_count(2048).should eq("2k")
    end

    it "keeps one decimal under 100k" do
      Hcode::LLM::TokenCounter.format_count(50_552).should eq("49.4k")
      Hcode::LLM::TokenCounter.format_count(262_144).should eq("256k")
    end

    it "rounds to a whole number at or above 100k" do
      Hcode::LLM::TokenCounter.format_count(102_400).should eq("100k")
      Hcode::LLM::TokenCounter.format_count(999_999).should eq("977k")
    end

    it "formats mega boundaries on 1024*1024" do
      Hcode::LLM::TokenCounter.format_count(1_048_576).should eq("1M")
      Hcode::LLM::TokenCounter.format_count(1_572_864).should eq("1.5M")
      Hcode::LLM::TokenCounter.format_count(10_485_760).should eq("10M")
    end

    it "clamps negatives to zero" do
      Hcode::LLM::TokenCounter.format_count(-1).should eq("0")
    end
  end
end
