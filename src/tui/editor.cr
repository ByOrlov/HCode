module Hcode
  module TUI
    class Editor < Component
      @lines : Array(String) = [""]
      @cursor_row : Int32 = 0
      @cursor_col : Int32 = 0
      @history : Array(String) = [] of String
      @history_index : Int32 = -1
      @draft : String = ""
      @placeholder : String = ""

      property? multiline : Bool = true
      property placeholder : String
      property fg_color : Int32 = 252
      property accent_color : Int32 = 75

      def initialize(@placeholder : String = "")
      end

      def text : String
        @lines.join('\n')
      end

      def clear : Nil
        @lines = [""]
        @cursor_row = 0
        @cursor_col = 0
      end

      def set(text : String) : Nil
        @lines = text.split('\n')
        @lines = [""] if @lines.empty?
        @cursor_row = @lines.size - 1
        @cursor_col = @lines.last.size
      end

      def empty? : Bool
        @lines.size == 1 && @lines[0].empty?
      end

      def insert_text(text : String) : Nil
        return if text.empty?

        # Insert at current cursor position, preserving newlines.
        prefix = @lines[@cursor_row][0...@cursor_col] || ""
        suffix = @lines[@cursor_row][@cursor_col..] || ""
        pasted_lines = text.split('\n')
        pasted_lines[0] = prefix + pasted_lines[0]
        pasted_lines[-1] = pasted_lines[-1] + suffix

        @lines[@cursor_row] = pasted_lines[0]
        if pasted_lines.size > 1
          pasted_lines[1..].reverse_each do |line|
            @lines.insert(@cursor_row + 1, line)
          end
        end

        @cursor_row += pasted_lines.size - 1
        @cursor_col = pasted_lines.last.size - suffix.size
        clamp_cursor_col
      end

      def handle_input(key : KeyEvent) : Bool
        case key.key
        when .char?
          if c = key.char
            insert_char(c)
            true
          else
            false
          end
        when .enter?
          if key.shift
            insert_newline
            true
          else
            false
          end
        when .backspace?
          if key.alt
            delete_word_back
          else
            backspace
          end
          true
        when .delete?
          delete_forward
          true
        when .left?
          cursor_left
          true
        when .right?
          cursor_right
          true
        when .up?
          if @multiline && @cursor_row > 0
            @cursor_row -= 1
            clamp_cursor_col
          elsif @history.any?
            navigate_history(-1)
          end
          true
        when .down?
          if @multiline && @cursor_row < @lines.size - 1
            @cursor_row += 1
            clamp_cursor_col
          elsif @history_index >= 0
            navigate_history(1)
          end
          true
        when .home?
          @cursor_col = 0
          true
        when .end?
          @cursor_col = @lines[@cursor_row].size
          true
        else
          false
        end
      end

      def submit! : String
        text = self.text.strip
        unless text.empty?
          @history << text
        end
        @history_index = -1
        clear
        text
      end

      def render(io : IO) : Nil
        if empty? && !@placeholder.empty?
          io << ANSI.color(240, nil)
          io << @placeholder
          io << ANSI.clear_line
          io << ANSI.reset
          return
        end

        @lines.each_with_index do |line, i|
          if i == @cursor_row
            before = line[0...@cursor_col] || ""
            after = line[@cursor_col..] || ""
            io << ANSI.color(@fg_color, nil)
            io << before
            if after.empty?
              io << " "
              io << ANSI.color(@accent_color, nil)
              io << ANSI.dim
            else
              io << ANSI.color(@accent_color, nil)
              io << after[0]? || " "
              io << after[1..] if after.size > 1
            end
            io << ANSI.reset
          else
            io << ANSI.color(@fg_color, nil)
            io << line
            io << ANSI.clear_line
            io << ANSI.reset
          end
          io << "\n" if i < @lines.size - 1
        end
      end

      def measure(width : Int32, height : Int32) : Int32
        @width = width
        h = {@lines.size, 1}.max
        @height = h
        h
      end

      def cursor_position : {Int32, Int32}
        {@cursor_row, @cursor_col}
      end

      private def insert_char(c : Char) : Nil
        line = @lines[@cursor_row]
        @lines[@cursor_row] = line.insert(@cursor_col, c)
        @cursor_col += 1
      end

      private def insert_newline : Nil
        line = @lines[@cursor_row]
        before = line[0...@cursor_col] || ""
        after = line[@cursor_col..] || ""
        @lines[@cursor_row] = before
        @lines.insert(@cursor_row + 1, after)
        @cursor_row += 1
        @cursor_col = 0
      end

      private def backspace : Nil
        if @cursor_col > 0
          line = @lines[@cursor_row]
          @lines[@cursor_row] = line[0...@cursor_col - 1] + line[@cursor_col..]
          @cursor_col -= 1
        elsif @cursor_row > 0
          prev_line = @lines[@cursor_row - 1]
          @cursor_col = prev_line.size
          @lines[@cursor_row - 1] = prev_line + @lines[@cursor_row]
          @lines.delete_at(@cursor_row)
          @cursor_row -= 1
        end
      end

      private def delete_word_back : Nil
        line = @lines[@cursor_row]
        col = @cursor_col

        if col == 0
          if @cursor_row > 0
            prev_line = @lines[@cursor_row - 1]
            @cursor_col = prev_line.size
            @lines[@cursor_row - 1] = prev_line + line
            @lines.delete_at(@cursor_row)
            @cursor_row -= 1
          end
          return
        end

        i = col - 1
        while i > 0 && line[i].ascii_whitespace?
          i -= 1
        end
        word_start = i
        while word_start > 0 && !line[word_start - 1].ascii_whitespace?
          word_start -= 1
        end

        @lines[@cursor_row] = line[0...word_start] + line[col..]
        @cursor_col = word_start
      end

      private def delete_forward : Nil
        line = @lines[@cursor_row]
        if @cursor_col < line.size
          @lines[@cursor_row] = line[0...@cursor_col] + line[@cursor_col + 1..]
        elsif @cursor_row < @lines.size - 1
          @lines[@cursor_row] = line + @lines[@cursor_row + 1]
          @lines.delete_at(@cursor_row + 1)
        end
      end

      private def cursor_left : Nil
        if @cursor_col > 0
          @cursor_col -= 1
        elsif @cursor_row > 0
          @cursor_row -= 1
          @cursor_col = @lines[@cursor_row].size
        end
      end

      private def cursor_right : Nil
        if @cursor_col < @lines[@cursor_row].size
          @cursor_col += 1
        elsif @cursor_row < @lines.size - 1
          @cursor_row += 1
          @cursor_col = 0
        end
      end

      private def clamp_cursor_col : Nil
        max_col = @lines[@cursor_row].size
        @cursor_col = {@cursor_col, max_col}.min
      end

      private def navigate_history(direction : Int32) : Nil
        if @history_index == -1
          @draft = text
          @history_index = @history.size
        end

        new_index = @history_index + direction
        return if new_index < -1 || new_index >= @history.size

        @history_index = new_index
        content = if new_index == -1
                    @draft
                  else
                    @history[new_index]
                  end

        @lines = content.split('\n')
        @lines = [""] if @lines.empty?
        @cursor_row = @lines.size - 1
        @cursor_col = @lines.last.size
      end
    end
  end
end
