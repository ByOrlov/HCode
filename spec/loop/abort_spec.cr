require "../spec_helper"

describe Hcode::Loop::AbortController do
  it "starts non-aborted" do
    Hcode::Loop::AbortController.new.aborted?.should be_false
  end

  it "records the abort reason" do
    ctrl = Hcode::Loop::AbortController.new
    ctrl.abort("user pressed escape")
    ctrl.aborted?.should be_true
    ctrl.reason.should eq("user pressed escape")
  end

  it "throws a UserCancellationError once aborted" do
    ctrl = Hcode::Loop::AbortController.new
    ctrl.abort("cancelled")
    expect_raises(Hcode::Loop::UserCancellationError) do
      ctrl.throw_if_aborted!
    end
  end

  describe "#reset!" do
    it "clears the aborted flag and reason so later turns can run" do
      ctrl = Hcode::Loop::AbortController.new
      ctrl.abort("cancelled")
      ctrl.aborted?.should be_true

      ctrl.reset!

      ctrl.aborted?.should be_false
      ctrl.reason.should be_nil
      ctrl.throw_if_aborted!
    end
  end
end

describe Hcode::Loop do
  describe ".execute_tool" do
    it "completes a tool that takes longer than 2 seconds (no wall-clock timeout)" do
      ctrl = Hcode::Loop::AbortController.new

      result = Hcode::Loop.execute_tool(ctrl) do
        sleep 3.seconds
        Hcode::Tools::ToolResult.success("done after 3s")
      end

      result.is_error.should be_false
      result.content.should contain("done after 3s")
    end

    it "returns the result immediately when the tool finishes fast" do
      ctrl = Hcode::Loop::AbortController.new

      result = Hcode::Loop.execute_tool(ctrl) do
        Hcode::Tools::ToolResult.success("instant")
      end

      result.content.should eq("instant")
      result.is_error.should be_false
    end

    it "arms grace timeout immediately when already aborted before start" do
      ctrl = Hcode::Loop::AbortController.new
      ctrl.abort("pre-cancelled")

      result = Hcode::Loop.execute_tool(ctrl, grace_timeout: 100.milliseconds) do
        sleep 10.seconds
        Hcode::Tools::ToolResult.success("never")
      end

      result.is_error.should be_true
      result.content.should contain("grace period")
    end

    it "returns a grace-timeout error when abort fires and tool doesn't finish in time" do
      ctrl = Hcode::Loop::AbortController.new
      ctrl.abort("test")

      result = Hcode::Loop.execute_tool(ctrl, grace_timeout: 100.milliseconds) do
        sleep 10.seconds
        Hcode::Tools::ToolResult.success("never")
      end

      result.is_error.should be_true
      result.content.should contain("grace period")
    end

    it "allows the tool to finish within the grace period after abort" do
      ctrl = Hcode::Loop::AbortController.new

      spawn do
        sleep 50.milliseconds
        ctrl.abort("test")
      end

      result = Hcode::Loop.execute_tool(ctrl, grace_timeout: 2.seconds) do
        sleep 200.milliseconds
        Hcode::Tools::ToolResult.success("finished during grace")
      end

      result.is_error.should be_false
      result.content.should contain("finished during grace")
    end
  end
end
