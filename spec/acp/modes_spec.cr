require "../spec_helper"
require "../../src/acp/server" # loads Acp::Modes

describe Hcode::Acp::Modes do
  describe ".valid?" do
    it "accepts the 4 canonical modes" do
      Hcode::Acp::Modes.valid?("default").should be_true
      Hcode::Acp::Modes.valid?("plan").should be_true
      Hcode::Acp::Modes.valid?("auto").should be_true
      Hcode::Acp::Modes.valid?("yolo").should be_true
    end

    it "rejects unknown modes" do
      Hcode::Acp::Modes.valid?("manual").should be_false
      Hcode::Acp::Modes.valid?("ask").should be_false
      Hcode::Acp::Modes.valid?("").should be_false
    end
  end

  describe ".to_toggles" do
    it "default → {false, Manual}" do
      plan, perm = Hcode::Acp::Modes.to_toggles("default")
      plan.should be_false
      perm.should eq(Hcode::Permission::Mode::Manual)
    end

    it "plan → {true, Manual}" do
      plan, perm = Hcode::Acp::Modes.to_toggles("plan")
      plan.should be_true
      perm.should eq(Hcode::Permission::Mode::Manual)
    end

    it "auto → {false, Auto}" do
      plan, perm = Hcode::Acp::Modes.to_toggles("auto")
      plan.should be_false
      perm.should eq(Hcode::Permission::Mode::Auto)
    end

    it "yolo → {false, Yolo}" do
      plan, perm = Hcode::Acp::Modes.to_toggles("yolo")
      plan.should be_false
      perm.should eq(Hcode::Permission::Mode::Yolo)
    end

    it "unknown → {false, Manual} (safe fallback)" do
      plan, perm = Hcode::Acp::Modes.to_toggles("unknown")
      plan.should be_false
      perm.should eq(Hcode::Permission::Mode::Manual)
    end
  end

  describe ".from_permission" do
    it "maps Manual → default" do
      Hcode::Acp::Modes.from_permission(Hcode::Permission::Mode::Manual).should eq("default")
    end

    it "maps Auto → auto" do
      Hcode::Acp::Modes.from_permission(Hcode::Permission::Mode::Auto).should eq("auto")
    end

    it "maps Yolo → yolo" do
      Hcode::Acp::Modes.from_permission(Hcode::Permission::Mode::Yolo).should eq("yolo")
    end
  end
end
