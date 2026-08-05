#!/usr/bin/env crystal
#
# lines_demo — prints the terminal cursor row (1-based) that the program
# started on, then exits. Used to verify the CPR (Cursor Position Report)
# query works against real terminals.
#
# Build: crystal build bin/lines_demo.cr -o bin/lines_demo --release
# Run:   ./bin/lines_demo

{% if flag?(:unix) %}
  lib LibCExtra
    VMIN  = 6
    VTIME = 5

    fun tcgetattr(fd : Int32, termios : LibC::Termios*) : Int32
    fun tcsetattr(fd : Int32, optional_actions : Int32, termios : LibC::Termios*) : Int32
  end
{% end %}

# Query the cursor position via CPR (\e[6n). The terminal replies with
# \e[<row>;<col>R on stdin. Returns the 1-based row, or nil on timeout.
def cursor_row : Int32?
  {% if flag?(:unix) %}
    fd = STDIN.fd

    # Save original termios, switch to raw to read the CPR reply without
    # line buffering / echo.
    orig = uninitialized LibC::Termios
    LibCExtra.tcgetattr(fd, pointerof(orig))

    raw = orig
    raw.c_lflag &= ~(LibC::ICANON | LibC::ECHO | LibC::ISIG | LibC::IEXTEN)
    raw.c_iflag &= ~(LibC::IXON | LibC::ICRNL)
    raw.c_oflag &= ~LibC::OPOST
    raw.c_cc[LibCExtra::VMIN] = 0
    raw.c_cc[LibCExtra::VTIME] = 1 # 100ms timeout per read

    LibCExtra.tcsetattr(fd, LibC::TCSANOW, pointerof(raw))

    # Send CPR request
    print "\e[6n"
    STDOUT.flush

    # Read the reply: \e[<row>;<col>R
    buf = [] of UInt8
    start = Time.monotonic
    loop do
      byte = uninitialized UInt8[1]
      n = LibC.read(fd, byte, 1)
      if n > 0
        buf << byte[0]
        break if byte[0] == 'R'.ord
      end
      break if (Time.monotonic - start).total_milliseconds > 500
    end

    # Restore original termios
    LibCExtra.tcsetattr(fd, LibC::TCSANOW, pointerof(orig))

    reply = String.new(buf.to_unsafe, buf.size)
    if match = reply.match(/\e\[(\d+);(\d+)R/)
      match[1].to_i32
    end
  {% else %}
    # Windows: GetConsoleScreenBufferInfo gives cursor_position directly.
    h = LibCConsole.getStdHandle(LibCConsole::STD_OUTPUT_HANDLE)
    info = uninitialized LibCConsole::ConsoleScreenBufferInfo
    if h && !h.null? && LibCConsole.getConsoleScreenBufferInfo(h, pointerof(info)) != 0
      info.cursor_position.y.to_i32 + 1
    end
  {% end %}
end

if row = cursor_row
  puts "#{row} lines"
else
  puts "not a tty"
  exit 1
end
