require "../spec_helper"
require "yaml"

def collect_keys(hash, prefix = "") : Array(String)
  keys = [] of String
  hash.each do |k, v|
    full_key = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
    if v.is_a?(Hash)
      keys.concat(collect_keys(v, full_key))
    else
      keys << full_key
    end
  end
  keys
end

describe H2code::I18n do
  describe "locale files" do
    locale_dir = File.join(__DIR__, "..", "..", "src", "i18n", "locales")

    it "contains en.yml and ru.yml" do
      File.exists?(File.join(locale_dir, "en.yml")).should be_true
      File.exists?(File.join(locale_dir, "ru.yml")).should be_true
    end

    it "has parity between en and ru keys" do
      en_data = YAML.parse(File.read(File.join(locale_dir, "en.yml"))).as_h["en"].as_h
      ru_data = YAML.parse(File.read(File.join(locale_dir, "ru.yml"))).as_h["ru"].as_h

      en_keys = collect_keys(en_data).sort
      ru_keys = collect_keys(ru_data).sort

      missing_in_ru = en_keys - ru_keys
      missing_in_en = ru_keys - en_keys

      missing_in_ru.should be_empty, "Keys missing in ru.yml: #{missing_in_ru.inspect}"
      missing_in_en.should be_empty, "Keys missing in en.yml: #{missing_in_en.inspect}"
    end
  end

  describe ".resolve_locale" do
    it "returns config language when supported" do
      H2code::I18n.resolve_locale("ru").should eq("ru")
      H2code::I18n.resolve_locale("en").should eq("en")
    end

    it "falls back when config language is unsupported" do
      H2code::I18n.resolve_locale("fr", {"LANG" => "en_US"}).should eq("en")
    end

    it "reads H2CODE_LANG env" do
      env = {"H2CODE_LANG" => "ru"}
      H2code::I18n.resolve_locale(nil, env).should eq("ru")
    end

    it "parses LANG with region and encoding" do
      H2code::I18n.resolve_locale(nil, {"LANG" => "ru_RU.UTF-8"}).should eq("ru")
      H2code::I18n.resolve_locale(nil, {"LANG" => "en_US.UTF-8"}).should eq("en")
    end

    it "defaults to en for unsupported system locale" do
      H2code::I18n.resolve_locale(nil, {"LANG" => "fr_FR.UTF-8"}).should eq("en")
    end

    it "defaults to en with no env" do
      H2code::I18n.resolve_locale(nil, {} of String => String).should eq("en")
    end
  end

  describe ".available_locales" do
    it "includes en and ru" do
      locales = H2code::I18n.available_locales
      locales.should contain("en")
      locales.should contain("ru")
    end
  end

  describe ".t" do
    it "translates keys after init" do
      H2code::I18n.init("en")
      H2code.t("status.turn_complete").should eq("Turn complete")

      H2code::I18n.activate("ru")
      H2code.t("status.turn_complete").should eq("Ход завершён")
    end

    it "returns the key for missing translations" do
      H2code::I18n.init("en")
      H2code.t("nonexistent.key").should eq("nonexistent.key")
    end

    it "interpolates params" do
      H2code::I18n.init("en")
      H2code.t("errors.generic", message: "boom").should eq("Error: boom")
    end
  end
end
