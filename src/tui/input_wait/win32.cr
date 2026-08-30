{% skip_file unless flag?(:win32) %}

module H2code
  module TUI
    # Windows adapter: wait on the console input handle via WaitForSingleObject.
    #
    # The STD_INPUT_HANDLE is signaled whenever the console input queue holds
    # unread events, which for the brief collect-bytes window used by Input is
    # behaviourally equivalent to poll() on POSIX. (A redirected STDIN coming
    # from a pipe or file is not covered here; that case needs overlapped I/O
    # and is out of scope until the rest of the TUI is Windows-ready.)
    class Win32InputWait < InputWait
      private lib LibKernel32
        STD_INPUT_HANDLE = 0xFFFFFFF6_u32 # (DWORD)-10
        WAIT_FAILED      = 0xFFFFFFFF_u32
        WAIT_TIMEOUT     = 0x00000102_u32

        alias HANDLE = Void*
        alias DWORD = UInt32

        fun GetStdHandle(n_std_handle : DWORD) : HANDLE
        fun WaitForSingleObject(handle : HANDLE, milliseconds : DWORD) : DWORD
      end

      def stdin_readable?(timeout : Time::Span) : Bool
        handle = LibKernel32.GetStdHandle(LibKernel32::STD_INPUT_HANDLE)
        ms = timeout.total_milliseconds.round.clamp(0, 0xFFFFFFFF).to_u32
        result = LibKernel32.WaitForSingleObject(handle, ms)
        result != LibKernel32::WAIT_TIMEOUT && result != LibKernel32::WAIT_FAILED
      end
    end
  end
end
