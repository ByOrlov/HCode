module Hcode
  module TUI
    abstract class Component
      getter width : Int32 = 0
      getter height : Int32 = 0
      property visible : Bool = true

      def render(io : IO) : Nil
      end

      def handle_input(key : KeyEvent) : Bool
        false
      end

      def measure(width : Int32, height : Int32) : Int32
        @width = width
        @height = 1
        1
      end
    end
  end
end
