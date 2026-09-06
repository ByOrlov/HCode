require "json"
require "../tools/ask_user_question"
require "./json_rpc"

module H2code
  module Acp
    # Bridges AskUserQuestion's interactive prompt over a custom reverse-RPC
    # (`session/request_question`) to the ACP client — in the h2chat chain
    # that is the h2code-remote daemon, which forwards the questions to the
    # chat UI as an `ask.question` frame and answers with the user's
    # selections (see h2chat PROTOCOL.md).
    #
    # Mirrors PlanReviewHandler: blocks the tool call until the user answers.
    # On RPC failure/timeout returns an empty result — the tool then reports
    # the dismissed branch (`{"answers":{},"note":…}`).
    class QuestionHandler < Tools::QuestionService
      QUESTION_TIMEOUT = 30.minutes # user deliberates; same budget as plan review

      def initialize(@rpc : JsonRpc, @session_id : String)
      end

      def request(req : Tools::QuestionRequest,
                  signal : ::H2code::Loop::AbortController?) : Tools::QuestionResult?
        params = build_params(req)
        response = @rpc.request("session/request_question", params, QUESTION_TIMEOUT)
        self.class.map_response(response)
      rescue ex : ReverseRpcError
        STDERR.puts "[acp] question RPC failed: #{ex.message}"
        Tools::QuestionResult.new
      rescue ex
        STDERR.puts "[acp] question error: #{ex}"
        Tools::QuestionResult.new
      end

      # --- Builders ---

      private def build_params(req : Tools::QuestionRequest) : JSON::Any
        questions = req.questions.map do |q|
          h = {"question" => JSON::Any.new(q.question)} of String => JSON::Any
          h["header"] = JSON::Any.new(q.header) unless q.header.empty?
          h["multiSelect"] = JSON::Any.new(q.multi_select?) if q.multi_select?
          h["options"] = JSON::Any.new(q.options.map do |o|
            oh = {"label" => JSON::Any.new(o.label)} of String => JSON::Any
            oh["description"] = JSON::Any.new(o.description) unless o.description.empty?
            JSON::Any.new(oh)
          end)
          JSON::Any.new(h)
        end
        JSON::Any.new({
          "sessionId" => JSON::Any.new(@session_id),
          "questions" => JSON::Any.new(questions),
        } of String => JSON::Any)
      end

      # --- Response mapping (pure — unit-testable without JsonRpc) ---

      # Response shape: `{answers: {question text => label(s)}}`. Missing or
      # empty `answers` means the user dismissed the question — an empty
      # QuestionResult maps to the tool's dismissed branch.
      def self.map_response(response : JSON::Any) : Tools::QuestionResult
        result = Tools::QuestionResult.new
        answers = response["answers"]?
        return result unless answers && answers.raw.is_a?(Hash)
        answers.as_h.each do |question, answer|
          result[question] = answer.to_s
        end
        result
      end
    end
  end
end
