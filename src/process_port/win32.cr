{% skip_file unless flag?(:win32) %}

module H2code
  # Windows adapter: force-kill via `Process#terminate(graceful: false)`, which
  # the Crystal stdlib maps to `TerminateProcess`.
  #
  # Windows has no SIGKILL/SIGTERM distinction: both graceful and forceful
  # termination go through `TerminateProcess`, which the kernel applies
  # immediately. The distinction is preserved at the API level only for
  # symmetry with the Unix adapter and the two-phase kill ladders in the tools.
  class Win32ProcessPort < ProcessPort
    def force_kill(process : Process) : Nil
      process.terminate(graceful: false) rescue nil
    end
  end
end
