require "../spec_helper"

def write_tips_file(dir : String, locale : String, tips : Array(Tuple(String, String))) : Nil
  entries = tips.map { |code, text| %({"code": #{code.to_json}, "text": #{text.to_json}}) }
  File.write(File.join(dir, "#{locale}.json"), "[\n#{entries.join(",\n")}\n]\n")
end

describe H2code::Tips do
  it "loads tips and random_tip returns one of their texts" do
    with_tmpdir do |dir|
      write_tips_file(dir, "ru", [{"voice_input", "Говорите голосом"}, {"tips_disable", "/tips off"}])
      tips = H2code::Tips.load("ru", [dir]).not_nil!
      tips.map(&.code).should eq(["voice_input", "tips_disable"])
      {"Говорите голосом", "/tips off"}.should contain(H2code::Tips.random_tip("ru", [dir]))
    end
  end

  it "falls back to en.json when the locale file is missing" do
    with_tmpdir do |dir|
      write_tips_file(dir, "en", [{"voice_input", "Speak by voice"}])
      H2code::Tips.random_tip("ja", [dir]).should eq("Speak by voice")
    end
  end

  it "returns nil when no tips dir exists" do
    with_tmpdir do |dir|
      H2code::Tips.load("en", [File.join(dir, "nope")]).should be_nil
      H2code::Tips.random_tip("en", [File.join(dir, "nope")]).should be_nil
    end
  end

  it "returns nil on malformed JSON" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "en.json"), "{not json")
      H2code::Tips.load("en", [dir]).should be_nil
    end
  end

  it "skips entries without code or text" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "en.json"), %([{"code":"a","text":"ok"},{"code":"","text":"bad"},{"code":"c"}]))
      tips = H2code::Tips.load("en", [dir]).not_nil!
      tips.map(&.code).should eq(["a"])
    end
  end

  it "reads the repo tips folder: every supported locale has a voice_input tip" do
    repo_tips = File.expand_path("../../tips", __DIR__)
    H2code::I18n::SUPPORTED_LOCALES.each do |loc|
      tips = H2code::Tips.load(loc, [repo_tips]).not_nil!
      tips.map(&.code).should contain("voice_input")
    end
  end
end
