module Hcode
  module Notify
    enum AgentStatus
      Idle
      Working
      Done
      InputRequired
    end

    # A transition between two statuses, with the payload a channel needs to
    # decide whether and what to deliver. `body` is optional context (e.g. the
    # tool that needs approval); channels may ignore it.
    record Transition,
      event : String, # "turn_started", "turn_done", "input_required", "idle"
      prev_status : AgentStatus,
      next_status : AgentStatus,
      title : String = "",
      body : String = "",
      session_id : String = "",
      timestamp : String = Time.utc.to_rfc3339

    # Owns the current status and fans every real transition out to a block.
    # Only actual changes fire — staying in `Working` across many steps emits
    # nothing, which keeps long tool-heavy turns quiet.
    class StatusTracker
      getter status : AgentStatus = AgentStatus::Idle
      @on_transition : Transition -> Nil

      def initialize(&@on_transition : Transition -> Nil)
      end

      def transition!(next_status : AgentStatus, title : String = "", body : String = "") : Nil
        prev = @status
        return if prev == next_status # no-op: same status, no transition

        @status = next_status
        event = event_for(prev, next_status)
        payload = Transition.new(event, prev, next_status, title, body)
        @on_transition.call(payload)
      end

      # Maps a (prev, next) edge onto a stable event name. Only transitions the
      # plan cares about produce a non-empty event; unknown edges fall back to
      # the next status name so they still reach the dispatcher.
      private def event_for(prev : AgentStatus, next_status : AgentStatus) : String
        case {prev, next_status}
        when {AgentStatus::Idle, AgentStatus::Working}          then "turn_started"
        when {AgentStatus::Working, AgentStatus::Done}          then "turn_done"
        when {AgentStatus::Done, AgentStatus::Idle}             then "settled"
        when {_, AgentStatus::InputRequired}                    then "input_required"
        when {AgentStatus::InputRequired, AgentStatus::Working} then "resumed"
        else                                                         next_status.to_s.downcase
        end
      end
    end
  end
end
