lib LibCExtra
  VMIN  = 6
  VTIME = 5

  TIOCGWINSZ = 0x5413

  struct Winsize
    ws_row : UInt16
    ws_col : UInt16
    ws_xpixel : UInt16
    ws_ypixel : UInt16
  end

  fun ioctl(fd : Int32, request : UInt32, ...) : Int32
  fun isatty(fd : Int32) : Int32
end

module Hcode
  module TUI
    class Terminal
      @original_termios : LibC::Termios?
      @raw : Bool = false

      def self.current : Terminal
        @@current ||= new
      end

      def initialize
        @cols, @rows = size
      end

      getter cols : Int32
      getter rows : Int32

      def raw! : Nil
        return if @raw
        fd = STDIN.fd

        orig = uninitialized LibC::Termios
        LibC.tcgetattr(fd, pointerof(orig))
        @original_termios = orig

        raw_termios = orig
        raw_termios.c_lflag &= ~(LibC::ICANON | LibC::ECHO | LibC::ISIG | LibC::IEXTEN)
        raw_termios.c_iflag &= ~(LibC::IXON | LibC::ICRNL)
        raw_termios.c_oflag &= ~LibC::OPOST
        raw_termios.c_cc[LibCExtra::VMIN] = 0
        raw_termios.c_cc[LibCExtra::VTIME] = 0

        LibC.tcsetattr(fd, LibC::TCSAFLUSH, pointerof(raw_termios))
        @raw = true

        print ANSI.hide_cursor
        print "\e[?2004h" # Enable bracketed paste mode
      end

      def restore! : Nil
        return unless @raw
        fd = STDIN.fd

        print "\e[?2004l" # Disable bracketed paste mode
        print ANSI.show_cursor
        print "\r\n"

        if orig = @original_termios
          restored = orig
          LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(restored))
        end
        @raw = false
      end

      def refresh_size : Nil
        @cols, @rows = size
      end

      def tty? : Bool
        LibCExtra.isatty(STDIN.fd) == 1
      end

      private def size : {Int32, Int32}
        ws = uninitialized LibCExtra::Winsize
        ret = LibCExtra.ioctl(STDOUT.fd, LibCExtra::TIOCGWINSZ, pointerof(ws))
        if ret == 0 && ws.ws_col > 0 && ws.ws_row > 0
          {ws.ws_col.to_i32, ws.ws_row.to_i32}
        else
          env_cols = ENV["COLUMNS"]?.try(&.to_i?) || 80
          env_rows = ENV["LINES"]?.try(&.to_i?) || 24
          {env_cols, env_rows}
        end
      end
    end

    module ANSI
      ESC = "\e["

      def self.cursor_to(row : Int32, col : Int32) : String
        "#{ESC}#{row + 1};#{col + 1}H"
      end

      def self.cursor_up(n : Int32 = 1) : String
        "#{ESC}#{n}A"
      end

      def self.cursor_down(n : Int32 = 1) : String
        "#{ESC}#{n}B"
      end

      def self.clear_line : String
        "#{ESC}2K"
      end

      def self.clear_screen : String
        "#{ESC}2J"
      end

      def self.clear_below : String
        "#{ESC}J"
      end

      def self.hide_cursor : String
        "#{ESC}?25l"
      end

      def self.show_cursor : String
        "#{ESC}?25h"
      end

      def self.alt_screen_on : String
        "#{ESC}?1049h"
      end

      def self.alt_screen_off : String
        "#{ESC}?1049l"
      end

      def self.color(fg : Int32? = nil, bg : Int32? = nil) : String
        parts = [] of String
        parts << "38;5;#{fg}" if fg
        parts << "48;5;#{bg}" if bg
        parts.empty? ? "" : "#{ESC}#{parts.join(";")}m"
      end

      def self.reset : String
        "#{ESC}0m"
      end

      def self.bold : String
        "#{ESC}1m"
      end

      def self.dim : String
        "#{ESC}2m"
      end

      def self.italic : String
        "#{ESC}3m"
      end

      def self.underline : String
        "#{ESC}4m"
      end

      def self.rgb(r : Int32, g : Int32, b : Int32) : String
        "#{ESC}38;2;#{r};#{g};#{b}m"
      end
    end
  end
end
