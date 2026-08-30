module H2code
  module TUI
    struct Style
      property fg : Int32? = nil
      property bg : Int32? = nil
      property? bold : Bool = false
      property? dim : Bool = false
      property? italic : Bool = false
      property? underline : Bool = false

      def initialize(
        @fg : Int32? = nil,
        @bg : Int32? = nil,
        @bold : Bool = false,
        @dim : Bool = false,
        @italic : Bool = false,
        @underline : Bool = false,
      )
      end

      def to_ansi : String
        parts = [] of String
        parts << ANSI.bold if @bold
        parts << ANSI.dim if @dim
        parts << ANSI.italic if @italic
        parts << ANSI.underline if @underline
        parts << ANSI.color(@fg, nil) if @fg
        parts << ANSI.color(nil, @bg) if @bg
        parts.join
      end
    end

    struct StyledSegment
      property text : String
      property style : Style

      def initialize(@text : String, @style : Style = Style.new)
      end
    end

    class Text < Component
      @segments : Array(StyledSegment)
      @lines : Array(String) = [] of String

      def initialize(text : String = "", style : Style = Style.new)
        @segments = [StyledSegment.new(text, style)]
        rebuild_lines
      end

      def initialize(@segments : Array(StyledSegment))
        rebuild_lines
      end

      def text : String
        @segments.map(&.text).join
      end

      def set(text : String, style : Style = Style.new) : Nil
        @segments = [StyledSegment.new(text, style)]
        rebuild_lines
      end

      def append(segment : StyledSegment) : Nil
        @segments << segment
        rebuild_lines
      end

      def clear : Nil
        @segments.clear
        @lines.clear
      end

      def render(io : IO) : Nil
        @lines.each_with_index do |line, i|
          io << ANSI.cursor_to(@height > 0 ? 0 : 0, 0) if i == 0
          io << line
          io << ANSI.clear_line
          io << "\n" if i < @lines.size - 1
        end
      end

      def measure(width : Int32, height : Int32) : Int32
        @width = width
        rebuild_lines(width)
        h = @lines.empty? ? 1 : @lines.size
        @height = h
        h
      end

      private def rebuild_lines(max_width : Int32 = 0) : Nil
        full = String.build do |s|
          @segments.each do |seg|
            s << seg.style.to_ansi
            s << seg.text
            s << ANSI.reset
          end
        end

        if max_width > 0
          @lines = wrap_lines(full, max_width)
        else
          @lines = full.split('\n')
        end
      end

      private def wrap_lines(text : String, max_width : Int32) : Array(String)
        text.split('\n').flat_map do |line|
          if visible_width(line) <= max_width
            [line]
          else
            wrap_single_line(line, max_width)
          end
        end.to_a
      end

      private def wrap_single_line(line : String, max_width : Int32) : Array(String)
        result = [] of String
        current = String::Builder.new
        current_width = 0

        line.split(' ').each do |word|
          word_w = visible_width(word)
          if current_width + (current_width > 0 ? 1 : 0) + word_w > max_width && current_width > 0
            result << current.to_s
            current = String::Builder.new
            current_width = 0
          end
          current << ' ' if current_width > 0
          current << word
          current_width += (current_width > 0 ? 1 : 0) + word_w
        end
        result << current.to_s unless current.to_s.empty?
        result
      end

      private def visible_width(s : String) : Int32
        CharWidth.visible_width(s)
      end
    end
  end
end
