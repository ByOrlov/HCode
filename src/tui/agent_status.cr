module Hcode
  module TUI
    # Lifecycle status of the agent, shown as a permanent one-line indicator
    # in the Active zone (always next to the editor, never disappears).
    #
    # State transitions:
    #
    #   Hello → Busy            (user submits a prompt)
    #   Busy  → Done            (turn completes normally)
    #   Busy  → Error           (turn cancelled / errored)
    #   Busy  → Waiting         (approval / question / sudo pending)
    #   Waiting → Busy          (approval resolved)
    #   Done/Error → Busy       (next prompt submitted)
    enum AgentStatus
      Hello   # Startup, nothing done yet — bar khaki, text gray
      Busy    # Agent working — blue, spinner animates
      Waiting # Waiting for user input — yellow
      Done    # Turn finished — bar khaki, text gray, shows step/tool summary
      Error   # Interrupted / errored — red
    end
  end
end
