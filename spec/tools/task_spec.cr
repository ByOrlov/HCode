require "../spec_helper"
require "../../src/tools/task"

def make_task(id : String, status : Hcode::Tools::AgentTaskStatus = Hcode::Tools::AgentTaskStatus::Running,
              description : String = "test task",
              started_at : Int64 = 1_i64,
              command : String? = nil,
              pid : Int64? = nil,
              exit_code : Int32? = nil,
              stop_reason : String? = nil,
              ended_at : Int64? = nil) : Hcode::Tools::AgentTaskInfo
  Hcode::Tools::AgentTaskInfo.new(
    task_id: id,
    description: description,
    status: status,
    started_at: started_at,
    ended_at: ended_at,
    stop_reason: stop_reason,
    command: command,
    pid: pid,
    exit_code: exit_code,
  )
end

describe Hcode::Tools::TaskList do
  before_each do
    Hcode::Tools::Task.service = Hcode::Tools::InMemoryTaskService.new
  end
  after_each do
    Hcode::Tools::Task.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::TaskList.new
    tool.name.should eq("TaskList")
    props = tool.parameters["properties"].as_h
    props.has_key?("active_only").should be_true
    props.has_key?("limit").should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "returns 'No background tasks' when empty" do
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_false
    result.content.should eq("active_background_tasks: 0\nNo background tasks found.")
  end

  it "uses 'background_tasks' label when active_only=false" do
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({ "active_only": false })))
    result.is_error.should be_false
    result.content.should contain("background_tasks: 0")
    result.content.should_not contain("active_background_tasks")
  end

  it "lists tasks with all key fields" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(
      id: "bash-1",
      description: "npm run build",
      command: "npm run build",
      pid: 12345_i64,
    ))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_false
    result.content.should contain("active_background_tasks: 1")
    result.content.should contain("task_id: bash-1")
    result.content.should contain("description: npm run build")
    result.content.should contain("status: running")
    result.content.should contain("command: npm run build")
    result.content.should contain("pid: 12345")
  end

  it "filters out terminal tasks when active_only=true (default)" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    service.register(make_task(id: "bash-2", status: Hcode::Tools::AgentTaskStatus::Completed))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({})))
    result.content.should contain("active_background_tasks: 1")
    result.content.should contain("task_id: bash-1")
    result.content.should_not contain("task_id: bash-2")
  end

  it "includes terminal tasks when active_only=false" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    service.register(make_task(id: "bash-2", status: Hcode::Tools::AgentTaskStatus::Completed))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({ "active_only": false })))
    result.content.should contain("background_tasks: 2")
  end

  it "respects limit parameter" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    service.register(make_task(id: "bash-2"))
    service.register(make_task(id: "bash-3"))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({ "limit": 2 })))
    result.content.should contain("active_background_tasks: 2")
  end

  it "rejects limit=0 (clamped to 1)" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({ "limit": 0 })))
    result.is_error.should be_false
    result.content.should contain("active_background_tasks: 1")
  end

  it "records separated by ---" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    service.register(make_task(id: "bash-2"))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({})))
    result.content.should contain("\n---\n")
  end

  it "converts CamelCase keys to snake_case" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1", pid: 123_i64, command: "x", exit_code: nil, stop_reason: "killed"))
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({})))
    result.content.should contain("task_id:")
    result.content.should contain("started_at:")
    result.content.should contain("stop_reason: killed")
  end

  it "fails when no service is registered" do
    Hcode::Tools::Task.service = nil
    tool = Hcode::Tools::TaskList.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_true
    result.content.should contain("not initialized")
  end
end

describe Hcode::Tools::TaskOutput do
  before_each do
    Hcode::Tools::Task.service = Hcode::Tools::InMemoryTaskService.new
  end
  after_each do
    Hcode::Tools::Task.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::TaskOutput.new
    tool.name.should eq("TaskOutput")
    props = tool.parameters["properties"].as_h
    props.has_key?("task_id").should be_true
    props.has_key?("block").should be_true
    props.has_key?("timeout").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["task_id"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "returns not_ready for running task (default block=false)" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.is_error.should be_false
    result.content.should contain("retrieval_status: not_ready")
    result.content.should contain("status: running")
  end

  it "returns timeout for running task with block=true" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1", "block": true })))
    result.is_error.should be_false
    result.content.should contain("retrieval_status: timeout")
    result.content.should contain("next_step:")
    result.content.should contain("Do not block on it again")
  end

  it "returns success for terminal task" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1", status: Hcode::Tools::AgentTaskStatus::Completed, exit_code: 0))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("retrieval_status: success")
    result.content.should contain("status: completed")
    result.content.should contain("exit_code: 0")
  end

  it "emits terminal_reason=stopped for killed task with stop_reason" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Killed,
      stop_reason: "Killed manually"))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("terminal_reason: stopped")
    result.content.should contain("stop_reason: Killed manually")
  end

  it "emits terminal_reason=timed_out for TimedOut task" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1", status: Hcode::Tools::AgentTaskStatus::TimedOut))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("terminal_reason: timed_out")
  end

  it "omits terminal_reason for plain completed exit" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Completed,
      exit_code: 0))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should_not contain("terminal_reason")
  end

  it "emits truncation banner when truncated with output_path" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Completed,
      exit_code: 0))
    service.set_output("bash-1",
      "a" * (Hcode::Tools::Task::OUTPUT_PREVIEW_BYTES + 100),
      output_path: "/tmp/x.log",
      full_output_available: true,
      truncated: true)
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("[Truncated. Full output: /tmp/x.log]")
    result.content.should contain("output_truncated: true")
    result.content.should contain("full_output_available: true")
    result.content.should contain("full_output_tool: Read")
    result.content.should contain("full_output_hint:")
  end

  it "emits no-full-log banner when truncated without persisted log" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Completed,
      exit_code: 0))
    service.set_output("bash-1",
      "a" * (Hcode::Tools::Task::OUTPUT_PREVIEW_BYTES + 100),
      output_path: nil,
      full_output_available: false,
      truncated: true)
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("[Truncated. No persisted full log is available for this task.]")
  end

  it "emits [no output available] when preview is empty" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Completed,
      exit_code: 0))
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("[output]")
    result.content.should contain("[no output available]")
  end

  it "renders preview after [output] marker" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Completed,
      exit_code: 0))
    service.set_output("bash-1", "Hello world")
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("[output]\nHello world")
  end

  it "returns Task not found for unknown id" do
    tool = Hcode::Tools::TaskOutput.new
    result = tool.execute(JSON.parse(%({ "task_id": "nope" })))
    result.is_error.should be_true
    result.content.should contain("Task not found: nope")
  end
end

describe Hcode::Tools::TaskStop do
  before_each do
    Hcode::Tools::Task.service = Hcode::Tools::InMemoryTaskService.new
  end
  after_each do
    Hcode::Tools::Task.service = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::TaskStop.new
    tool.name.should eq("TaskStop")
    props = tool.parameters["properties"].as_h
    props.has_key?("task_id").should be_true
    props.has_key?("reason").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["task_id"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "stops a running task with default reason" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.is_error.should be_false
    result.content.should contain("task_id: bash-1")
    result.content.should contain("status: killed")
    result.content.should contain("reason: Stopped by TaskStop")
  end

  it "stops a running task with custom reason" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1", "reason": "User killed" })))
    result.content.should contain("reason: User killed")
  end

  it "treats whitespace-only reason as default" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1"))
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1", "reason": "   " })))
    result.content.should contain("reason: Stopped by TaskStop")
  end

  it "returns status when task already terminal" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Completed,
      exit_code: 0))
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.is_error.should be_false
    result.content.should contain("task_id: bash-1")
    result.content.should contain("status: completed")
    result.content.should contain("reason: Task already in terminal state")
  end

  it "uses stored stop_reason when task already terminal and has one" do
    service = Hcode::Tools::Task.service.not_nil!
    service.register(make_task(id: "bash-1",
      status: Hcode::Tools::AgentTaskStatus::Failed,
      stop_reason: "timed out"))
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    result.content.should contain("reason: timed out")
  end

  it "suppresses terminal notification before stopping" do
    service = Hcode::Tools::Task.service.not_nil!
    info = service.register(make_task(id: "bash-1"))
    info.terminal_notification_suppressed.should be_nil
    tool = Hcode::Tools::TaskStop.new
    tool.execute(JSON.parse(%({ "task_id": "bash-1" })))
    info.terminal_notification_suppressed.should be_true
  end

  it "returns Task not found for unknown id" do
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "nope" })))
    result.is_error.should be_true
    result.content.should contain("Task not found: nope")
  end

  it "fails when no service is registered" do
    Hcode::Tools::Task.service = nil
    tool = Hcode::Tools::TaskStop.new
    result = tool.execute(JSON.parse(%({ "task_id": "x" })))
    result.is_error.should be_true
    result.content.should contain("not initialized")
  end
end

describe "Hcode::Tools::AgentTaskStatus" do
  it "to_wire emits snake_case" do
    Hcode::Tools::AgentTaskStatus::Running.to_wire.should eq("running")
    Hcode::Tools::AgentTaskStatus::Completed.to_wire.should eq("completed")
    Hcode::Tools::AgentTaskStatus::Failed.to_wire.should eq("failed")
    Hcode::Tools::AgentTaskStatus::TimedOut.to_wire.should eq("timed_out")
    Hcode::Tools::AgentTaskStatus::Killed.to_wire.should eq("killed")
    Hcode::Tools::AgentTaskStatus::Lost.to_wire.should eq("lost")
  end

  it "terminal? returns true for non-Running statuses" do
    Hcode::Tools::AgentTaskStatus::Running.terminal?.should be_false
    Hcode::Tools::AgentTaskStatus::Completed.terminal?.should be_true
    Hcode::Tools::AgentTaskStatus::Failed.terminal?.should be_true
    Hcode::Tools::AgentTaskStatus::TimedOut.terminal?.should be_true
    Hcode::Tools::AgentTaskStatus::Killed.terminal?.should be_true
    Hcode::Tools::AgentTaskStatus::Lost.terminal?.should be_true
  end
end

describe "Hcode::Tools.render_notification_xml" do
  it "renders a full notification block" do
    xml = Hcode::Tools.render_notification_xml({
      "id"          => JSON::Any.new("task-1"),
      "category"    => JSON::Any.new("task_completion"),
      "type"        => JSON::Any.new("agent_completed"),
      "source_kind" => JSON::Any.new("agent"),
      "source_id"   => JSON::Any.new("agent-1"),
      "agent_id"    => JSON::Any.new("agent-1"),
      "title"       => JSON::Any.new("Subagent completed"),
      "severity"    => JSON::Any.new("info"),
      "body"        => JSON::Any.new("Result: ok"),
    } of String => JSON::Any)
    xml.should contain(%(<notification id="task-1" category="task_completion" type="agent_completed" source_kind="agent" source_id="agent-1" agent_id="agent-1">))
    xml.should contain("Title: Subagent completed")
    xml.should contain("Severity: info")
    xml.should contain("Result: ok")
    xml.should contain("</notification>")
  end

  it "falls back to 'unknown' for missing required attrs" do
    xml = Hcode::Tools.render_notification_xml({} of String => JSON::Any)
    xml.should contain(%(id="unknown"))
    xml.should contain(%(category="unknown"))
    xml.should contain(%(type="unknown"))
    xml.should contain(%(source_kind="unknown"))
    xml.should contain(%(source_id="unknown"))
    xml.should_not contain("agent_id=")
    xml.should_not contain("Title:")
    xml.should_not contain("Severity:")
  end

  it "escapes XML special chars in attribute values" do
    xml = Hcode::Tools.render_notification_xml({
      "id"   => JSON::Any.new(%(a "b" & <c>)),
      "type" => JSON::Any.new("x"),
    } of String => JSON::Any)
    xml.should contain(%(id="a &quot;b&quot; &amp; &lt;c&gt;"))
  end

  it "renders children when provided" do
    xml = Hcode::Tools.render_notification_xml({
      "id"       => JSON::Any.new("x"),
      "children" => JSON::Any.new([JSON::Any.new("line1"), JSON::Any.new("line2")] of JSON::Any),
    } of String => JSON::Any)
    xml.should contain("line1")
    xml.should contain("line2")
  end
end

describe "Hcode::Tools.snake_case_key" do
  it "converts CamelCase to snake_case" do
    Hcode::Tools.snake_case_key("taskId").should eq("task_id")
    Hcode::Tools.snake_case_key("outputPath").should eq("output_path")
    Hcode::Tools.snake_case_key("startedAt").should eq("started_at")
    Hcode::Tools.snake_case_key("fullOutputAvailable").should eq("full_output_available")
    Hcode::Tools.snake_case_key("simple").should eq("simple")
  end
end
