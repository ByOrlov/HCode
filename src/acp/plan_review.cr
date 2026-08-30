require "json"
require "../tools/plan_mode"
require "./json_rpc"

module Hcode
  module Acp
    # Bridges ExitPlanMode's interactive plan review over a custom reverse-RPC
    # (`session/plan_review`) to the ACP client — in the hibechat chain that is
    # the hcode-remote daemon, which forwards the payload to the chat UI as a
    # `plan.review` frame and answers with the user's decision
    # (see hibechat PROTOCOL.md).
    #
    # Mirrors the TUI's AppPlanReviewService: blocks the tool call until the
    # user decides. On RPC failure/timeout returns nil — ExitPlanMode then
    # Falls back to the Dismissed branch (plan mode stays active).
    class PlanReviewHandler < Tools::PlanReviewService
      REVIEW_TIMEOUT = 30.minutes # user deliberates longer than the 120 s reverse-RPC default

      def initialize(@rpc : JsonRpc, @session_id : String)
      end

      def request(plan : String, path : String?,
                  options : Array(Tools::PlanOption)?) : Tools::PlanReviewResult?
        params = build_params(plan, path, options)
        response = @rpc.request("session/plan_review", params, REVIEW_TIMEOUT)
        self.class.map_response(response)
      rescue ex : ReverseRpcError
        STDERR.puts "[acp] plan review RPC failed: #{ex.message}"
        nil
      rescue ex
        STDERR.puts "[acp] plan review error: #{ex}"
        nil
      end

      # --- Builders ---

      private def build_params(plan : String, path : String?,
                               options : Array(Tools::PlanOption)?) : JSON::Any
        opts = (options || [] of Tools::PlanOption).map do |o|
          h = {"label" => JSON::Any.new(o.label)} of String => JSON::Any
          h["description"] = JSON::Any.new(o.description) unless o.description.empty?
          JSON::Any.new(h)
        end
        params = {
          "sessionId" => JSON::Any.new(@session_id),
          "plan"      => JSON::Any.new(plan),
        } of String => JSON::Any
        params["path"] = JSON::Any.new(path) if path
        params["options"] = JSON::Any.new(opts) unless opts.empty?
        JSON::Any.new(params)
      end

      # --- Response mapping (pure — unit-tested without JsonRpc) ---

      def self.map_response(response : JSON::Any) : Tools::PlanReviewResult?
        case response["decision"]?.try(&.to_s)
        when "approve"
          label = response["selectedLabel"]?.try(&.to_s)
          label = nil if label && label.empty?
          Tools::PlanReviewResult.new(Tools::PlanReviewDecision::Approve, label)
        when "revise"
          Tools::PlanReviewResult.new(Tools::PlanReviewDecision::Revise,
            feedback: response["feedback"]?.try(&.to_s) || "")
        when "reject"
          Tools::PlanReviewResult.new(Tools::PlanReviewDecision::RejectAndExit)
        else
          # "dismiss" / unknown / missing — Dismissed; nil (no result) maps to
          # the same branch in ExitPlanMode#handle_review_result.
          nil
        end
      end
    end
  end
end
