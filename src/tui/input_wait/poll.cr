{% skip_file if flag?(:win32) %}

module H2code
  module TUI
    # POSIX adapter: wait on STDIN readability via the poll(2) syscall.
    #
    # poll() works on any file descriptor (terminal, pipe, socket, regular
    # file) and behaves identically across all POSIX targets, so a single
    # implementation covers Linux, macOS and the BSDs.
    class PollInputWait < InputWait
      private lib LibCPoll
        struct PollFd
          fd : Int32
          events : Int16
          revents : Int16
        end

        POLLIN = 0x001_i16

        # nfds is declared UInt (4 bytes); the System V / AAPCS64 calling
        # conventions zero-extend sub-word integer arguments to the full
        # register, so this stays correct on targets where C's nfds_t is
        # unsigned long (8 bytes), e.g. 64-bit glibc Linux.
        fun poll(fds : PollFd*, nfds : UInt32, timeout : Int32) : Int32
      end

      def stdin_readable?(timeout : Time::Span) : Bool
        pfd = uninitialized LibCPoll::PollFd
        pfd.fd = STDIN.fd
        pfd.events = LibCPoll::POLLIN

        ms = timeout.total_milliseconds.round.to_i32.clamp(0, Int32::MAX)
        ret = LibCPoll.poll(pointerof(pfd), 1_u32, ms)

        ret > 0 && (pfd.revents & LibCPoll::POLLIN) != 0
      end
    end
  end
end
