require "../spec_helper"
require "../../src/tools/plan_mode"
require "file_utils"

private def with_plan_service(&)
  dir = File.join(ENV["TMPDIR"]? || "/tmp", "plan_mode_spec_#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  service = Hcode::Tools::AgentPlanService.new(dir, "agent-test", File.join(dir, "plan.md"))
  Hcode::Tools::PlanMode.plan_service = service
  Hcode::Tools::PlanMode.permission_mode = nil
  begin
    yield service, dir
  ensure
    Hcode::Tools::PlanMode.plan_service = nil
    Hcode::Tools::PlanMode.permission_mode = nil
    FileUtils.rm_rf(dir)
  end
end

describe Hcode::Tools::EnterPlanMode do
  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::EnterPlanMode.new
    tool.name.should eq("EnterPlanMode")
    tool.description.should contain("non-trivial implementation")

    tool.parameters["properties"].as_h.empty?.should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "fails when plan mode is already active" do
    with_plan_service do |service|
      service.enter
      tool = Hcode::Tools::EnterPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error.should be_true
      result.content.should contain("already active")
    end
  end

  it "enters plan mode and returns message with plan file" do
    with_plan_service do |service|
      tool = Hcode::Tools::EnterPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error.should be_false
      result.content.should contain("Plan mode is now active")
      result.content.should contain("Plan file:")
      result.content.should contain("Write the plan to the plan file")
      service.status.should_not be_nil
    end
  end

  it "renders message without path when plan_path is nil" do
    # Custom service that keeps path nil even after enter.
    service = Hcode::Tools::PlanServiceSpecHelper::NoPathPlanService.new
    Hcode::Tools::PlanMode.plan_service = service
    tool = Hcode::Tools::EnterPlanMode.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_false
    result.content.should contain("no plan file path is available")
    Hcode::Tools::PlanMode.plan_service = nil
  end

  it "fails when no service is registered" do
    Hcode::Tools::PlanMode.plan_service = nil
    tool = Hcode::Tools::EnterPlanMode.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_true
    result.content.should contain("Plan service is not initialized")
  end
end

describe Hcode::Tools::ExitPlanMode do
  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::ExitPlanMode.new
    tool.name.should eq("ExitPlanMode")
    tool.description.should contain("plan mode")
    props = tool.parameters["properties"].as_h
    props.has_key?("options").should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "fails when plan mode is not active" do
    with_plan_service do |service|
      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error.should be_true
      result.content.should contain("can only be called while plan mode is active")
    end
  end

  it "fails when plan file is empty (path known)" do
    with_plan_service do |service, dir|
      service.enter
      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error.should be_true
      result.content.should contain("No plan file found")
      result.content.should contain("plan.md")
    end
  end

  it "exits plan mode in auto permission mode with auto-approved message" do
    with_plan_service do |service, dir|
      path = File.join(dir, "plan.md")
      File.write(path, "## Plan\n\nStep 1: do thing.\n")
      service.enter

      Hcode::Tools::PlanMode.permission_mode = Hcode::Tools::PermissionModeRef.new(auto: true)

      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error.should be_false
      result.content.should contain("Exited plan mode")
      result.content.should contain("auto-approved without user review")
      result.content.should contain("## Plan (auto-approved")
      result.content.should contain("Step 1: do thing.")
      service.status.should be_nil
    end
  end

  it "exits plan mode in manual mode with approved message" do
    with_plan_service do |service, dir|
      path = File.join(dir, "plan.md")
      File.write(path, "Plan body.")
      service.enter

      Hcode::Tools::PlanMode.permission_mode = Hcode::Tools::PermissionModeRef.new(auto: false)

      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error.should be_false
      result.content.should contain("Exited plan mode")
      result.content.should contain("## Approved Plan:")
      result.content.should contain("Plan body.")
    end
  end

  it "rejects duplicate option labels" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [
          {"label": "Approach A"},
          {"label": "approach a"}
        ]
      })))
      result.is_error.should be_true
      result.content.should contain("Option labels must be unique")
    end
  end

  it "rejects reserved option labels" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label": "Reject"}]
      })))
      result.is_error.should be_true
      result.content.should contain("reserved approval labels")
    end
  end

  it "rejects too many options" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"}]
      })))
      result.is_error.should be_true
      result.content.should contain("between 1 and 3")
    end
  end

  it "rejects empty option label" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = Hcode::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label": ""}]
      })))
      result.is_error.should be_true
      result.content.should contain("label")
    end
  end

  it "fails when no service is registered" do
    Hcode::Tools::PlanMode.plan_service = nil
    tool = Hcode::Tools::ExitPlanMode.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error.should be_true
    result.content.should contain("Plan service is not initialized")
  end
end

# Helpers for plan-mode specs.
module Hcode::Tools::PlanServiceSpecHelper
  class NoPathPlanService < Hcode::Tools::PlanService
    @active : Bool = false
    @id : String = "test-plan-id"

    def status : Hcode::Tools::PlanData?
      return nil unless @active
      Hcode::Tools::PlanData.new(id: @id, content: "", path: nil)
    end

    def enter(id : String? = nil, create_file : Bool = false) : Nil
      @active = true
    end

    def cancel(id : String? = nil) : Nil
      @active = false
    end

    def clear : Nil
      @active = false
    end

    def exit(id : String? = nil) : Nil
      @active = false
    end
  end
end
