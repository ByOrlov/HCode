require "../spec_helper"
require "../../src/acp/server" # loads Acp::Modes

describe H2code::Acp::Modes do
  describe ".valid?" do
    it "accepts the 4 canonical modes" do
      H2code::Acp::Modes.valid?("default").should be_true
      H2code::Acp::Modes.valid?("plan").should be_true
      H2code::Acp::Modes.valid?("auto").should be_true
      H2code::Acp::Modes.valid?("yolo").should be_true
    end

    it "rejects unknown modes" do
      H2code::Acp::Modes.valid?("manual").should be_false
      H2code::Acp::Modes.valid?("ask").should be_false
      H2code::Acp::Modes.valid?("").should be_false
    end
  end

  describe ".to_toggles" do
    it "default → {false, Manual}" do
      plan, perm = H2code::Acp::Modes.to_toggles("default")
      plan.should be_false
      perm.should eq(H2code::Permission::Mode::Manual)
    end

    it "plan → {true, Manual}" do
      plan, perm = H2code::Acp::Modes.to_toggles("plan")
      plan.should be_true
      perm.should eq(H2code::Permission::Mode::Manual)
    end

    it "auto → {false, Auto}" do
      plan, perm = H2code::Acp::Modes.to_toggles("auto")
      plan.should be_false
      perm.should eq(H2code::Permission::Mode::Auto)
    end

    it "yolo → {false, Yolo}" do
      plan, perm = H2code::Acp::Modes.to_toggles("yolo")
      plan.should be_false
      perm.should eq(H2code::Permission::Mode::Yolo)
    end

    it "unknown → {false, Manual} (safe fallback)" do
      plan, perm = H2code::Acp::Modes.to_toggles("unknown")
      plan.should be_false
      perm.should eq(H2code::Permission::Mode::Manual)
    end
  end

  describe ".from_permission" do
    it "maps Manual → default" do
      H2code::Acp::Modes.from_permission(H2code::Permission::Mode::Manual).should eq("default")
    end

    it "maps Auto → auto" do
      H2code::Acp::Modes.from_permission(H2code::Permission::Mode::Auto).should eq("auto")
    end

    it "maps Yolo → yolo" do
      H2code::Acp::Modes.from_permission(H2code::Permission::Mode::Yolo).should eq("yolo")
    end
  end
end
