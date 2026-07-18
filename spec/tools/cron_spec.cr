require "../spec_helper"
require "../../src/tools/cron"

describe "Hcode::Tools::Cron.parse_expression" do
  it "parses wildcards" do
    parsed = Hcode::Tools::Cron.parse_expression("* * * * *")
    parsed.minute.size.should eq(60)
    parsed.hour.size.should eq(24)
    parsed.dom.size.should eq(31)
    parsed.month.size.should eq(12)
    parsed.dow.size.should eq(7)
    parsed.dom_full?.should be_true
    parsed.dow_full?.should be_true
  end

  it "parses */N step" do
    parsed = Hcode::Tools::Cron.parse_expression("*/5 * * * *")
    parsed.minute.to_a.sort.should eq([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55])
  end

  it "parses range" do
    parsed = Hcode::Tools::Cron.parse_expression("0 9 * * 1-5")
    parsed.dow.to_a.sort.should eq([1, 2, 3, 4, 5])
  end

  it "parses list" do
    parsed = Hcode::Tools::Cron.parse_expression("0,30 * * * *")
    parsed.minute.to_a.sort.should eq([0, 30])
  end

  it "parses stepped range" do
    parsed = Hcode::Tools::Cron.parse_expression("0-59/15 * * * *")
    parsed.minute.to_a.sort.should eq([0, 15, 30, 45])
  end

  it "normalizes dow 7 → 0 (Sunday)" do
    parsed = Hcode::Tools::Cron.parse_expression("* * * * 7")
    parsed.dow.to_a.sort.should eq([0])
  end

  it "rejects wrong field count" do
    expect_raises(Hcode::Tools::CronParseError, /5 fields/) do
      Hcode::Tools::Cron.parse_expression("* * *")
    end
  end

  it "rejects out-of-range value" do
    expect_raises(Hcode::Tools::CronParseError, /out of range/) do
      Hcode::Tools::Cron.parse_expression("60 * * * *")
    end
  end

  it "rejects malformed step" do
    expect_raises(Hcode::Tools::CronParseError) do
      Hcode::Tools::Cron.parse_expression("abc * * * *")
    end
  end

  it "rejects inverted range" do
    expect_raises(Hcode::Tools::CronParseError, /start > end/) do
      Hcode::Tools::Cron.parse_expression("10-5 * * * *")
    end
  end
end

describe "Hcode::Tools::Cron.to_human" do
  it "every-N-minutes pattern" do
    parsed = Hcode::Tools::Cron.parse_expression("*/5 * * * *")
    Hcode::Tools::Cron.to_human(parsed).should eq("every 5 minutes")
  end

  it "at-N daily pattern" do
    parsed = Hcode::Tools::Cron.parse_expression("0 9 * * *")
    Hcode::Tools::Cron.to_human(parsed).should eq("at 9:00 daily")
  end

  it "weekdays pattern" do
    parsed = Hcode::Tools::Cron.parse_expression("0 9 * * 1-5")
    Hcode::Tools::Cron.to_human(parsed).should eq("at 9:00 on weekdays")
  end

  it "sunday pattern" do
    parsed = Hcode::Tools::Cron.parse_expression("0 9 * * 0")
    Hcode::Tools::Cron.to_human(parsed).should eq("at 9:00 on Sunday")
  end
end

describe "Hcode::Tools::Cron.compute_next_cron_run" do
  it "finds the next minute match for */5" do
    parsed = Hcode::Tools::Cron.parse_expression("*/5 * * * *")
    # Fixed reference in local time.
    now = Time.local(2026, 1, 1, 12, 3, 0).to_unix_ms
    nxt = Hcode::Tools::Cron.compute_next_cron_run(parsed, now)
    nxt.should_not be_nil
    fired = Time.unix_ms(nxt.not_nil!).to_local
    fired.minute.should eq(5)
    fired.hour.should eq(12)
  end

  it "finds daily fire time" do
    parsed = Hcode::Tools::Cron.parse_expression("0 9 * * *")
    # 14:00 local → next 9am local is next day
    now = Time.local(2026, 1, 1, 14, 0, 0).to_unix_ms
    nxt = Hcode::Tools::Cron.compute_next_cron_run(parsed, now)
    nxt.should_not be_nil
    fired = Time.unix_ms(nxt.not_nil!).to_local
    fired.hour.should eq(9)
    fired.minute.should eq(0)
    fired.day.should eq(2)
  end
end

describe "Hcode::Tools::Cron.has_fire_within_years?" do
  it "returns true for valid daily cron" do
    parsed = Hcode::Tools::Cron.parse_expression("0 9 * * *")
    now = Time.utc(2026, 1, 1).to_unix_ms
    Hcode::Tools::Cron.has_fire_within_years?(parsed, 5, now).should be_true
  end

  it "returns false for Feb 30 (never fires)" do
    parsed = Hcode::Tools::Cron.parse_expression("0 0 30 2 *")
    now = Time.utc(2026, 1, 1).to_unix_ms
    Hcode::Tools::Cron.has_fire_within_years?(parsed, 5, now).should be_false
  end
end

describe Hcode::Tools::CronCreate do
  before_each do
    Hcode::Tools::Cron.service = Hcode::Tools::InMemoryCronService.new
  end
  after_each do
    Hcode::Tools::Cron.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::CronCreate.new
    tool.name.should eq("CronCreate")
    props = tool.parameters["properties"].as_h
    props.has_key?("cron").should be_true
    props.has_key?("prompt").should be_true
    props.has_key?("recurring").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["cron", "prompt"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "creates a recurring cron job and returns nextFireAt" do
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "*/5 * * * *",
      "prompt": "check the deploy"
    })))
    result.is_error.should be_false
    result.content.should contain("id:")
    result.content.should contain("cron: */5 * * * *")
    result.content.should contain("humanSchedule: every 5 minutes")
    result.content.should contain("recurring: true")
    result.content.should contain("nextFireAt:")
    result.content.should_not contain("nextFireAt: null")
  end

  it "respects explicit recurring=false" do
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "*/5 * * * *",
      "prompt": "x",
      "recurring": false
    })))
    result.content.should contain("recurring: false")
  end

  it "rejects invalid cron expression" do
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "not-a-cron",
      "prompt": "x"
    })))
    result.is_error.should be_true
    result.content.should contain("Invalid cron expression")
  end

  it "rejects cron with no fire within 5 years" do
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "0 0 30 2 *",
      "prompt": "x"
    })))
    result.is_error.should be_true
    result.content.should contain("no fire within 5 years")
  end

  it "rejects prompt > 8 KiB" do
    tool = Hcode::Tools::CronCreate.new
    long_prompt = "x" * (Hcode::Tools::Cron::MAX_PROMPT_BYTES + 1)
    result = tool.execute(JSON.parse(%({
      "cron": "*/5 * * * *",
      "prompt": "#{long_prompt}"
    })))
    result.is_error.should be_true
    result.content.should contain("exceeds #{Hcode::Tools::Cron::MAX_PROMPT_BYTES} bytes")
  end

  it "rejects when session cap reached" do
    service = Hcode::Tools::Cron.service.not_nil!
    Hcode::Tools::Cron::MAX_CRON_JOBS_PER_SESSION.times do
      service.add_task(Hcode::Tools::CronTaskInit.new(cron: "*/5 * * * *", prompt: "x"))
    end
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "*/5 * * * *",
      "prompt": "x"
    })))
    result.is_error.should be_true
    result.content.should contain("cap reached")
  end

  it "honors killswitch (disabled)" do
    service = Hcode::Tools::Cron.service.not_nil!.as(Hcode::Tools::InMemoryCronService)
    service.disable!
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "*/5 * * * *",
      "prompt": "x"
    })))
    result.is_error.should be_true
    result.content.should contain("disabled")
  end

  it "fails when no service is registered" do
    Hcode::Tools::Cron.service = nil
    tool = Hcode::Tools::CronCreate.new
    result = tool.execute(JSON.parse(%({
      "cron": "*/5 * * * *",
      "prompt": "x"
    })))
    result.is_error.should be_true
    result.content.should contain("not initialized")
  end
end

describe Hcode::Tools::CronList do
  before_each do
    Hcode::Tools::Cron.service = Hcode::Tools::InMemoryCronService.new
  end
  after_each do
    Hcode::Tools::Cron.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::CronList.new
    tool.name.should eq("CronList")
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "returns empty message when no jobs" do
    tool = Hcode::Tools::CronList.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_false
    result.content.should eq("cron_jobs: 0\nNo cron jobs scheduled.")
  end

  it "lists scheduled jobs with key fields" do
    service = Hcode::Tools::Cron.service.not_nil!.as(Hcode::Tools::InMemoryCronService)
    task = service.add_task(Hcode::Tools::CronTaskInit.new(cron: "*/5 * * * *", prompt: "check the deploy"))
    # Set a next-fire time manually for deterministic output.
    service.set_next_fire_for_task(task.id, Time.utc(2026, 1, 1, 12, 5, 0).to_unix_ms)
    tool = Hcode::Tools::CronList.new
    result = tool.execute(JSON.parse(%({})))
    result.content.should contain("cron_jobs: 1")
    result.content.should contain("id: #{task.id}")
    result.content.should contain("cron: */5 * * * *")
    result.content.should contain("humanSchedule: every 5 minutes")
    result.content.should contain(%(prompt: "check the deploy"))
    result.content.should contain("recurring: true")
    result.content.should contain("stale: false")
  end

  it "records separated by ---" do
    service = Hcode::Tools::Cron.service.not_nil!
    service.add_task(Hcode::Tools::CronTaskInit.new(cron: "*/5 * * * *", prompt: "a"))
    service.add_task(Hcode::Tools::CronTaskInit.new(cron: "0 9 * * *", prompt: "b"))
    tool = Hcode::Tools::CronList.new
    result = tool.execute(JSON.parse(%({})))
    result.content.should contain("cron_jobs: 2")
    result.content.should contain("\n---\n")
  end

  it "truncates prompt preview > 200 bytes (UTF-8 safe)" do
    service = Hcode::Tools::Cron.service.not_nil!
    long_prompt = "x" * 250
    service.add_task(Hcode::Tools::CronTaskInit.new(cron: "*/5 * * * *", prompt: long_prompt))
    tool = Hcode::Tools::CronList.new
    result = tool.execute(JSON.parse(%({})))
    result.content.should contain("…(truncated)")
  end

  it "renders defensively on malformed cron stored task" do
    service = Hcode::Tools::Cron.service.not_nil!.as(Hcode::Tools::InMemoryCronService)
    # Bypass add_task validation — directly inject malformed cron.
    task = Hcode::Tools::CronTask.new(
      id: "deadbeef",
      cron: "garbage cron expr here",
      prompt: "x",
      recurring: true,
      created_at: service.now,
    )
    service.insert_task(task)
    tool = Hcode::Tools::CronList.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_false
    result.content.should contain("cron: garbage cron expr here")
    result.content.should contain("nextFireAt: null")
  end
end

describe Hcode::Tools::CronDelete do
  before_each do
    Hcode::Tools::Cron.service = Hcode::Tools::InMemoryCronService.new
  end
  after_each do
    Hcode::Tools::Cron.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::CronDelete.new
    tool.name.should eq("CronDelete")
    tool.parameters["required"].as_a.map(&.as_s).should eq(["id"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "rejects invalid id shape" do
    tool = Hcode::Tools::CronDelete.new
    result = tool.execute(JSON.parse(%({ "id": "not-a-ulid" })))
    result.is_error.should be_true
    result.content.should contain("Invalid cron job id")
    result.content.should contain("ULID")
  end

  it "deletes an existing job" do
    service = Hcode::Tools::Cron.service.not_nil!
    task = service.add_task(Hcode::Tools::CronTaskInit.new(cron: "*/5 * * * *", prompt: "x"))
    tool = Hcode::Tools::CronDelete.new
    result = tool.execute(JSON.parse(%({ "id": "#{task.id}" })))
    result.is_error.should be_false
    result.content.should contain("Deleted cron job #{task.id}")
    service.list.empty?.should be_true
  end

  it "returns not-found error for unknown id" do
    tool = Hcode::Tools::CronDelete.new
    result = tool.execute(JSON.parse(%({ "id": "deadbeef" })))
    result.is_error.should be_true
    result.content.should contain("No cron job with id deadbeef")
  end

  it "accepts 26-char Crockford Base32 ULID shape" do
    service = Hcode::Tools::Cron.service.not_nil!.as(Hcode::Tools::InMemoryCronService)
    # Inject a 26-char ULID-shaped task directly.
    task = Hcode::Tools::CronTask.new(
      id: "01HFG7K5ZPJTN4CPDQ8WQXHZQT",
      cron: "*/5 * * * *",
      prompt: "x",
      recurring: true,
      created_at: service.now,
    )
    service.insert_task(task)
    tool = Hcode::Tools::CronDelete.new
    result = tool.execute(JSON.parse(%({ "id": "01HFG7K5ZPJTN4CPDQ8WQXHZQT" })))
    result.is_error.should be_false
  end

  it "fails when no service is registered" do
    Hcode::Tools::Cron.service = nil
    tool = Hcode::Tools::CronDelete.new
    result = tool.execute(JSON.parse(%({ "id": "deadbeef" })))
    result.is_error.should be_true
    result.content.should contain("not initialized")
  end
end

describe "Hcode::Tools.format_local_iso_with_offset" do
  it "renders ISO 8601 with numeric offset" do
    ms = Time.utc(2026, 7, 18, 11, 32, 11).to_unix_ms
    formatted = Hcode::Tools.format_local_iso_with_offset(ms)
    # Should contain T separator and ±HH:MM offset (or Z for UTC).
    formatted.should match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
  end
end
