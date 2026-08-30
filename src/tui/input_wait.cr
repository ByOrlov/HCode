module H2code
  module TUI
    # Port: block until STDIN has bytes available to read, bounded by a timeout.
    #
    # The wait primitive is inherently OS-specific (poll on POSIX,
    # WaitForSingleObject on Windows) and is not provided by Crystal's stdlib in
    # a portable way anymore (IO::Evented#wait_readable is only compiled when
    # the LibEvent backend is selected). Concrete adapters implement the actual
    # syscall; application code (Input / collect_bytes) depends solely on this
    # abstraction. The adapter for the compile target is selected in exactly one
    # place - the composition root `default` below - so no platform branching
    # leaks into the rest of the TUI.
    abstract class InputWait
      # Returns true if STDIN becomes readable within *timeout*, false on timeout.
      abstract def stdin_readable?(timeout : Time::Span) : Bool

      # Composition root: instantiate the adapter matching the compile target.
      # This is the single point where the platform is decided.
      def self.default : InputWait
        {% if flag?(:win32) %}
          Win32InputWait.new
        {% else %}
          PollInputWait.new
        {% end %}
      end
    end
  end
end

require "./input_wait/poll"
require "./input_wait/win32"
