module Hcode
  module TUI
    class Spinner
      FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

      @frame : Int32 = 0
      @active : Bool = false
      @last_update : Time::Span = Time.monotonic

      def active? : Bool
        @active
      end

      def start : Nil
        @active = true
        @frame = 0
        @last_update = Time.monotonic
      end

      def stop : Nil
        @active = false
      end

      def render(io : IO, color : Int32 = 75) : Nil
        return unless @active

        now = Time.monotonic
        if (now - @last_update).total_milliseconds >= 80
          @frame = (@frame + 1) % FRAMES.size
          @last_update = now
        end

        io << ANSI.color(color, nil)
        io << FRAMES[@frame]
        io << ANSI.reset
      end

      def current_char : String
        FRAMES[@frame]
      end
    end
  end
end
