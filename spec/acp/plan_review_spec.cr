require "../spec_helper"
require "../../src/acp/plan_review"

describe H2code::Acp::PlanReviewHandler do
  describe ".map_response" do
    it "maps approve with a selected label" do
      res = H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({
        "decision": "approve", "selectedLabel": "Сквозной тракт"
      })))
      res.should_not be_nil
      if r = res
        r.decision.should eq(H2code::Tools::PlanReviewDecision::Approve)
        r.selected_label.should eq("Сквозной тракт")
        r.feedback.should eq("")
      end
    end

    it "maps approve without a label and drops empty labels" do
      res = H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({"decision": "approve"})))
      res.should_not be_nil
      if r = res
        r.selected_label.should be_nil
      end

      res = H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({
        "decision": "approve", "selectedLabel": ""
      })))
      res.should_not be_nil
      if r = res
        r.selected_label.should be_nil
      end
    end

    it "maps revise with feedback" do
      res = H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({
        "decision": "revise", "feedback": "добавь тесты"
      })))
      res.should_not be_nil
      if r = res
        r.decision.should eq(H2code::Tools::PlanReviewDecision::Revise)
        r.feedback.should eq("добавь тесты")
        r.selected_label.should be_nil
      end
    end

    it "maps reject to RejectAndExit" do
      res = H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({"decision": "reject"})))
      res.should_not be_nil
      if r = res
        r.decision.should eq(H2code::Tools::PlanReviewDecision::RejectAndExit)
      end
    end

    it "maps dismiss / unknown / missing decision to nil (Dismissed fallback)" do
      %w[dismiss cancel].each do |d|
        H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({"decision": "#{d}"}))).should be_nil
      end
      H2code::Acp::PlanReviewHandler.map_response(JSON.parse(%({}))).should be_nil
    end
  end
end
