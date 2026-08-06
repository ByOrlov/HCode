require "../spec_helper"
require "../../src/tools/ask_user_question"

# Тестовый QuestionService: возвращает заданный результат.
private class FakeService < Hcode::Tools::QuestionService
  def initialize(&block : Hcode::Tools::QuestionRequest, Hcode::Loop::AbortController? -> Hcode::Tools::QuestionResult?)
    @block = block
  end

  def request(req : Hcode::Tools::QuestionRequest, signal : Hcode::Loop::AbortController?) : Hcode::Tools::QuestionResult?
    @block.call(req, signal)
  end
end

private class FakeTasks < Hcode::Tools::AgentTaskService
  getter registered = [] of {String, Int32}

  def register_question_task(description : String, question_count : Int32, &run : Hcode::Loop::AbortController? -> String) : String
    @registered << {description, question_count}
    "task-#{registered.size}"
  end

  def task_status(task_id : String) : String?
    "running"
  end
end

describe Hcode::Tools::AskUserQuestion do
  after_each do
    Hcode::Tools::AskUserQuestion.service = nil
    Hcode::Tools::AskUserQuestion.tasks = nil
  end

  it "exposes the JS-name and identical schema" do
    tool = Hcode::Tools::AskUserQuestion.new
    tool.name.should eq("AskUserQuestion")
    tool.description.should contain("structured options")

    props = tool.parameters["properties"].as_h
    props.has_key?("questions").should be_true
    props.has_key?("background").should be_true

    qschema = props["questions"].as_h
    qschema["minItems"].as_i.should eq(1)
    qschema["maxItems"].as_i.should eq(4)

    items = qschema["items"].as_h
    items["additionalProperties"].as_bool.should be_false

    opts = items["properties"].as_h["options"].as_h
    opts["minItems"].as_i.should eq(2)
    opts["maxItems"].as_i.should eq(4)
  end

  it "fails when questions is missing" do
    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_true
    result.content.should contain("questions")
  end

  it "fails when there are too many questions" do
    tool = Hcode::Tools::AskUserQuestion.new
    qs = (1..5).map { |i| %( {"question":"Q#{i}?","options":[{"label":"a"},{"label":"b"}]} ) }.join(",")
    result = tool.execute(JSON.parse(%({ "questions": [#{qs}] })))
    result.is_error?.should be_true
    result.content.should contain("between 1 and 4")
  end

  it "fails when an option array has fewer than 2 entries" do
    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question": "Q?", "options": [{"label": "alone"}]}]
    })))
    result.is_error?.should be_true
    result.content.should contain("between 2 and 4")
  end

  it "fails when question text is empty" do
    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question": "", "options": [{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_true
    result.content.should contain("question")
  end

  it "fails on duplicate question text" do
    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [
        {"question": "Same?", "options": [{"label":"a"},{"label":"b"}]},
        {"question": "Same?", "options": [{"label":"c"},{"label":"d"}]}
      ]
    })))
    result.is_error?.should be_true
    result.content.should contain("duplicate question text")
    result.content.should contain("Rephrase the duplicates")
  end

  it "fails on duplicate option label within a question" do
    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [
        {"question": "Q?", "options": [{"label":"a"},{"label":"a"}]}
      ]
    })))
    result.is_error?.should be_true
    result.content.should contain("duplicate option label")
  end

  it "allows the same label across different questions" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      h = Hcode::Tools::QuestionResult.new
      h["Q1?"] = "a"
      h["Q2?"] = "a"
      h
    end

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [
        {"question": "Q1?", "options": [{"label":"a"},{"label":"b"}]},
        {"question": "Q2?", "options": [{"label":"a"},{"label":"b"}]}
      ]
    })))
    result.is_error?.should be_false
    result.content.should contain(%("Q1?":"a"))
    result.content.should contain(%("Q2?":"a"))
  end

  it "renders answered JSON without method field" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      h = Hcode::Tools::QuestionResult.new
      h["DB?"] = "SQLite"
      h
    end

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question":"DB?","options":[{"label":"SQLite"},{"label":"Postgres"}]}]
    })))
    result.is_error?.should be_false
    result.content.should contain(%("answers":))
    result.content.should contain(%("DB?":"SQLite"))
    result.content.should_not contain("method")
  end

  it "renders dismissed when service returns nil" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new { |req, sig| nil }

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_false
    result.content.should contain("User dismissed the question")
    result.content.should contain(%("answers":{}))
    result.content.should contain(%("note":))
  end

  it "renders dismissed when service returns empty hash" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      Hcode::Tools::QuestionResult.new
    end

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_false
    result.content.should contain("dismissed")
  end

  it "returns UNSUPPORTED error on NotImplementedError" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      raise NotImplementedError.new("not supported")
    end

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_true
    result.content.should contain("Do NOT call this tool again")
  end

  it "returns dismissed (not error) on a generic service exception" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      raise Exception.new("connection lost")
    end

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_false
    result.content.should contain("dismissed")
    result.content.should_not contain("Do NOT call")
  end

  it "returns unsupported failure when no service is registered" do
    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_true
    result.content.should contain("does not support interactive questions")
  end

  it "re-raises AbortError" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      raise Hcode::Tools::AbortError.new("aborted")
    end

    tool = Hcode::Tools::AskUserQuestion.new
    expect_raises(Hcode::Tools::AbortError) do
      tool.execute(JSON.parse(%({
        "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
      })))
    end
  end

  it "renders immediate background response with task_id" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      Hcode::Tools::QuestionResult.new
    end
    tasks = FakeTasks.new
    Hcode::Tools::AskUserQuestion.tasks = tasks

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "background": true,
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_false
    result.content.should contain("task_id: task-1")
    result.content.should contain("status: running")
    result.content.should contain("automatic_notification: true")
    result.content.should contain("next_step:")
    tasks.registered.size.should eq(1)
  end

  it "falls back to foreground when tasks service is missing despite background=true" do
    Hcode::Tools::AskUserQuestion.service = FakeService.new do |req, sig|
      h = Hcode::Tools::QuestionResult.new
      h["Q?"] = "a"
      h
    end

    tool = Hcode::Tools::AskUserQuestion.new
    result = tool.execute(JSON.parse(%({
      "background": true,
      "questions": [{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}]
    })))
    result.is_error?.should be_false
    result.content.should contain(%("answers":))
  end

  it "builds question description with +N more suffix" do
    tool = Hcode::Tools::AskUserQuestion.new
    q1 = Hcode::Tools::QuestionItem.new(question: "First?", options: [
      Hcode::Tools::QuestionOption.new(label: "a"),
      Hcode::Tools::QuestionOption.new(label: "b"),
    ])
    tool.question_description([q1]).should eq("First?")

    q2 = Hcode::Tools::QuestionItem.new(question: "Second?", options: [
      Hcode::Tools::QuestionOption.new(label: "a"),
      Hcode::Tools::QuestionOption.new(label: "b"),
    ])
    tool.question_description([q1, q2]).should eq("First? (+1 more)")
  end

  it "uses fallback description when questions have empty text" do
    tool = Hcode::Tools::AskUserQuestion.new
    q = Hcode::Tools::QuestionItem.new(question: "   ", options: [
      Hcode::Tools::QuestionOption.new(label: "a"),
      Hcode::Tools::QuestionOption.new(label: "b"),
    ])
    tool.question_description([q]).should eq("Ask user question")
  end
end
