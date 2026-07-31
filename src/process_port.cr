module Hcode
  # Port: forcibly terminate a running process.
  #
  # Forceful termination is inherently OS-specific (SIGKILL on POSIX,
  # TerminateProcess on Windows) and is not provided by Crystal's stdlib in a
  # portable way (`Process#terminate(graceful: false)` exists on both platforms
  # but the graceful path is the only signal-aware one on Unix). Concrete
  # adapters implement the actual syscall; application code depends solely on
  # this abstraction. The adapter for the compile target is selected in exactly
  # one place - the composition root `default` below - so no platform branching
  # leaks into the rest of the codebase.
  abstract class ProcessPort
    # Forcibly terminate *process* without giving it a chance to clean up.
    abstract def force_kill(process : Process) : Nil

    # Composition root: instantiate the adapter matching the compile target.
    # This is the single point where the platform is decided.
    def self.default : ProcessPort
      {% if flag?(:win32) %}
        Win32ProcessPort.new
      {% else %}
        UnixProcessPort.new
      {% end %}
    end
  end
end

require "./process_port/unix"
require "./process_port/win32"
