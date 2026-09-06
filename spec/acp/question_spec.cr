require "../spec_helper"
require "../../src/acp/question"

describe H2code::Acp::QuestionHandler do
  describe ".map_response" do
    it "maps answers keyed by question text" do
      res = H2code::Acp::QuestionHandler.map_response(JSON.parse(%({
        "answers": {
          "Какой формат конфига?": "YAML (Recommended)",
          "Нужна миграция?": "Да, автоматическая"
        }
      })))
      res.size.should eq(2)
      res["Какой формат конфига?"].should eq("YAML (Recommended)")
      res["Нужна миграция?"].should eq("Да, автоматическая")
    end

    it "maps multi-select answers verbatim (comma-joined labels)" do
      res = H2code::Acp::QuestionHandler.map_response(JSON.parse(%({
        "answers": { "Что подключить?": "Bash, Read" }
      })))
      res["Что подключить?"].should eq("Bash, Read")
    end

    it "maps missing / empty / non-object answers to dismissed (empty result)" do
      H2code::Acp::QuestionHandler.map_response(JSON.parse(%({}))).should be_empty
      H2code::Acp::QuestionHandler.map_response(JSON.parse(%({"answers": {}}))).should be_empty
      H2code::Acp::QuestionHandler.map_response(JSON.parse(%({"answers": "nope"}))).should be_empty
    end

    it "skips non-string question keys and stringifies answer values" do
      res = H2code::Acp::QuestionHandler.map_response(JSON.parse(%({
        "answers": { "Вопрос?": 42 }
      })))
      res.size.should eq(1)
      res["Вопрос?"].should eq("42")
    end
  end
end
