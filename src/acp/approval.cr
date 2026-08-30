require "json"
require "../permission/manager"
require "./json_rpc"

module H2code
  module Acp
    # Bridges H2Code's permission approval flow over ACP reverse-RPC.
    #
    # When the agent requests approval for a tool call, sends a
    # `session/request_permission` request to the IDE and blocks until the
    # user responds. On failure/timeout, returns `Deny` (safer than approving
    # when intent is unconfirmed).
    class ApprovalHandler
      def initialize(@rpc : JsonRpc, @session_id : String)
      end

      def call(tool_name : String, args : String, danger : String?) : Permission::ApprovalChoice
        options = build_options
        action_desc = build_action_description(tool_name, args, danger)
        params = build_params(@session_id, options, action_desc, tool_name, args)

        response = @rpc.request("session/request_permission", params)
        map_response(response)
      rescue ex : ReverseRpcError
        STDERR.puts "[acp] permission RPC failed: #{ex.message}"
        Permission::ApprovalChoice::Deny
      rescue ex
        STDERR.puts "[acp] permission error: #{ex}"
        Permission::ApprovalChoice::Deny
      end

      def callback : (String, String, String?) -> Permission::ApprovalChoice
        ->call(String, String, String?)
      end

      # --- Builders ---

      private def build_options : JSON::Any
        JSON.parse(%([
          {"id":"approve_once","label":"Allow Once","kind":"allow_once"},
          {"id":"approve_always","label":"Allow for Session","kind":"allow_always"},
          {"id":"reject","label":"Deny","kind":"reject_once"}
        ]))
      end

      private def build_params(session_id : String, options : JSON::Any,
                               action_desc : String, tool_name : String,
                               args : String) : JSON::Any
        JSON.parse(%({
          "sessionId": #{session_id.to_json},
          "options": #{options.to_json},
          "toolCall": {
            "title": #{tool_name.to_json},
            "status": "in_progress",
            "content": [
              {"type": "content", "content": {"type": "text", "text": #{action_desc.to_json}}}
            ]
          }
        }))
      end

      private def build_action_description(tool_name : String, args : String,
                                           danger : String?) : String
        desc = String.build do |s|
          s << "Requesting approval to run #{tool_name}"
          if danger
            s << "\n⚠ #{danger}"
          end
          unless args.empty?
            begin
              parsed = JSON.parse(args)
              if cmd = parsed["command"]?
                s << "\n$ #{cmd}"
              elsif path = (parsed["path"]? || parsed["filePath"]?)
                s << "\nfile: #{path}"
              end
            rescue
              # Args aren't JSON or don't have recognizable fields
            end
          end
        end
        desc
      end

      private def map_response(response : JSON::Any) : Permission::ApprovalChoice
        behavior = response["behavior"]?.try(&.to_s) || "deny"
        case behavior
        when "allow"
          Permission::ApprovalChoice::ApproveOnce
        when "allow-always"
          Permission::ApprovalChoice::ApproveSession
        else
          Permission::ApprovalChoice::Deny
        end
      end
    end
  end
end
