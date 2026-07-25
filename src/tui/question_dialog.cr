module Hcode
  module TUI
    # Full port of the TS `QuestionDialogComponent`
    # (`apps/kimi-code/src/tui/components/dialogs/question-dialog.ts`).
    #
    # Renders a tabbed multi-question prompt: one tab per question plus a
    # final Submit tab. Supports:
    #   - single-select and multi-select questions
    #   - a synthetic "Other" option per question with inline free-text entry
    #   - keyboard navigation (↑↓ ←/→ Tab Enter Esc, 1-9 hotkeys)
    #   - auto-advance to the next unanswered question after a single-select
    #   - a Submit review tab listing every answer before emitting
    #
    # On submit (Enter on "Submit"), emits the answers through a callback.
    # `answers[i]` is nil when question i was left blank; the whole result is
    # `{answers: []}` (dismissed) when the user presses Esc.
    class QuestionDialog
      MAX_BODY_LINES     = 12
      DEFAULT_OTHER      = "Other"
      NOT_ANSWERED       = "Not answered"
      REVIEW_TITLE       = "Review your answer before submit"
      SUBMIT_PROMPT      = "Ready to submit your answers?"
      UNANSWERED_WARNING = "Some questions are still unanswered."
      SUBMIT_ACTIONS     = ["Submit", "Cancel"]

      @questions : Array(Tools::QuestionItem)
      getter? visible : Bool = false
      property max_visible_options : Int32 = 6

      @theme : Theme
      @on_answer : (Hash(String, String) -> Nil)?
      @on_toggle_tool_output : (-> Nil)?

      # Tab state: index 0..n-1 = questions, n = submit tab.
      @current_tab : Int32 = 0
      @submit_action_idx : Int32 = 0
      @editing_other : Bool = false
      @review_message : String?

      # Per-question state arrays.
      @cursors : Array(Int32) = [] of Int32
      @single_selections : Array(Int32?) = [] of Int32?
      @multi_selections : Array(Set(Int32)) = [] of Set(Int32)
      @other_drafts : Array(String) = [] of String
      @committed_other : Array(String?) = [] of String?
      @answers : Array(String?) = [] of String?
      # Inline free-text buffer while editing the "Other" option.
      @other_input : String = ""

      def initialize(@theme : Theme = Theme.dark)
        @questions = [] of Tools::QuestionItem
      end

      def show(questions : Array(Tools::QuestionItem),
               on_answer : Hash(String, String) -> Nil,
               on_toggle_tool_output : (-> Nil)? = nil) : Nil
        @questions = questions
        @on_answer = on_answer
        @on_toggle_tool_output = on_toggle_tool_output
        total = questions.size
        @cursors = Array.new(total, 0)
        @single_selections = Array.new(total) { nil.as(Int32?) }
        @multi_selections = Array.new(total) { Set(Int32).new }
        @other_drafts = Array.new(total, "")
        @committed_other = Array.new(total) { nil.as(String?) }
        @answers = Array.new(total) { nil.as(String?) }
        @current_tab = 0
        @submit_action_idx = 0
        @editing_other = false
        @review_message = nil
        @other_input = ""
        @visible = true
      end

      def hide : Nil
        @visible = false
      end

      # ── Input ───────────────────────────────────────────────────────

      def handle_input(key : KeyEvent) : Nil
        case key.key
        when .escape?
          emit_answers([] of String)
          return
        when .ctrl_c?, .ctrl_d?
          emit_answers([] of String)
          return
        end

        if editing_other?
          handle_other_input(key)
          return
        end

        if submit_tab?
          handle_submit_input(key)
          return
        end

        qidx = current_question_index
        return unless qidx
        question = @questions[qidx]?
        return unless question
        option_count = display_options(qidx).size
        return if option_count == 0

        case key.key
        when .up?
          move_cursor(-1)
          return
        when .down?
          move_cursor(1)
          return
        when .left?
          goto_tab(@current_tab - 1)
          return
        when .right?, .tab?
          goto_tab(@current_tab + 1)
          return
        when .enter?
          activate_option(current_cursor, "enter")
          return
        end

        # Number-key hotkey (1-9).
        if key.key.char? && (ch = key.char)
          if ch.ascii_number?
            num_idx = ch.to_i - 1
            if num_idx >= 0 && num_idx < option_count
              @cursors[qidx] = num_idx
              activate_option(num_idx, "number_key")
              return
            end
          end
          if ch == ' ' && question.multi_select
            activate_option(current_cursor, "space")
            return
          end

          # Free-text chars while editing "Other".
          if editing_other? && (!ch.whitespace? || ch == ' ')
            @other_input += ch.to_s
            @other_drafts[qidx] = @other_input
            @review_message = nil
          end
        end
      end

      private def handle_other_input(key : KeyEvent) : Nil
        qidx = current_question_index
        return unless qidx

        case key.key
        when .tab?
          sync_other_draft(qidx)
          @editing_other = false
          goto_tab(@current_tab + 1)
          return
        when .up?
          sync_other_draft(qidx)
          @editing_other = false
          move_cursor(-1)
          return
        when .down?
          sync_other_draft(qidx)
          @editing_other = false
          move_cursor(1)
          return
        when .enter?
          commit_other_input(@other_input, "enter")
          return
        when .backspace?
          @other_input = @other_input.rchop
          @other_drafts[qidx] = @other_input
          @review_message = nil
          return
        when .escape?
          @editing_other = false
          return
        end

        if key.key.char? && (ch = key.char)
          return if ch.whitespace? && ch != ' '
          @other_input += ch.to_s
          @other_drafts[qidx] = @other_input
          @review_message = nil
        end
      end

      private def handle_submit_input(key : KeyEvent) : Nil
        case key.key
        when .up?
          @submit_action_idx = (@submit_action_idx - 1 + SUBMIT_ACTIONS.size) % SUBMIT_ACTIONS.size
          @review_message = nil
          return
        when .down?
          @submit_action_idx = (@submit_action_idx + 1) % SUBMIT_ACTIONS.size
          @review_message = nil
          return
        when .left?
          goto_tab(@current_tab - 1)
          return
        when .right?, .tab?
          goto_tab(@current_tab + 1)
          return
        when .enter?
          execute_submit_action(@submit_action_idx, "enter")
          return
        end

        if key.key.char?
          case key.char
          when '1'
            @submit_action_idx = 0
            execute_submit_action(0, "number_key")
          when '2'
            @submit_action_idx = 1
            execute_submit_action(1, "number_key")
          end
        end
      end

      # ── State mutation ──────────────────────────────────────────────

      private def goto_tab(target : Int32) : Nil
        total = total_tabs
        return if total <= 0
        wrapped = ((target % total) + total) % total
        return if wrapped == @current_tab
        @current_tab = wrapped
        @editing_other = false
        @review_message = nil
        @submit_action_idx = 0 if submit_tab?
      end

      private def move_cursor(delta : Int32) : Nil
        qidx = current_question_index
        return unless qidx
        total = display_options(qidx).size
        return if total <= 0
        @cursors[qidx] = (current_cursor + delta + total) % total
        @review_message = nil
      end

      private def activate_option(option_idx : Int32, method : String) : Nil
        qidx = current_question_index
        return unless qidx
        question = @questions[qidx]?
        return unless question

        @cursors[qidx] = option_idx
        @editing_other = false
        @review_message = nil

        if other_option?(qidx, option_idx)
          enter_other_input(qidx)
          return
        end

        if question.multi_select
          set = @multi_selections[qidx]
          if set.includes?(option_idx)
            set.delete(option_idx)
          else
            set.add(option_idx)
          end
          update_answer(qidx)
          return
        end

        @single_selections[qidx] = option_idx
        @committed_other[qidx] = nil
        update_answer(qidx)
        advance_after_single_select(qidx)
      end

      private def enter_other_input(qidx : Int32) : Nil
        @cursors[qidx] = other_option_index(qidx)
        @editing_other = true
        @other_input = @other_drafts[qidx]
        @review_message = nil
      end

      private def commit_other_input(raw_value : String, method : String) : Nil
        qidx = current_question_index
        return unless qidx
        question = @questions[qidx]?
        return unless question

        value = raw_value.strip
        return if value.empty?

        @other_input = value
        @other_drafts[qidx] = value
        @committed_other[qidx] = value

        if question.multi_select
          @multi_selections[qidx].add(other_option_index(qidx))
        else
          @single_selections[qidx] = other_option_index(qidx)
        end

        update_answer(qidx)
        @editing_other = false
        @review_message = nil

        advance_after_single_select(qidx) unless question.multi_select
      end

      private def advance_after_single_select(qidx : Int32) : Nil
        next_idx = find_next_unanswered_after(qidx)
        @current_tab = next_idx || submit_tab_index
        @review_message = nil
        @submit_action_idx = 0 if submit_tab?
      end

      private def find_next_unanswered_after(from_idx : Int32) : Int32?
        total = @questions.size
        (from_idx + 1...total).each do |i|
          return i unless answered?(i)
        end
        nil
      end

      private def update_answer(qidx : Int32) : Nil
        question = @questions[qidx]?
        return unless question

        if question.multi_select
          labels = [] of String
          set = @multi_selections[qidx]
          other_idx = other_option_index(qidx)
          question.options.each_with_index do |opt, i|
            next unless set.includes?(i)
            labels << opt.label unless opt.label.empty?
          end
          other_text = @committed_other[qidx]
          if set.includes?(other_idx) && other_text && !other_text.empty?
            labels << other_text
          end
          @answers[qidx] = labels.empty? ? nil : labels.join(", ")
          return
        end

        sel = @single_selections[qidx]
        if sel.nil?
          @answers[qidx] = nil
          return
        end

        if other_option?(qidx, sel)
          other_text = @committed_other[qidx]
          @answers[qidx] = (other_text && !other_text.empty?) ? other_text : nil
          return
        end

        label = question.options[sel]?.try(&.label)
        @answers[qidx] = (label && !label.empty?) ? label : nil
      end

      private def execute_submit_action(action_idx : Int32, method : String) : Nil
        if action_idx == 1
          emit_answers([] of String)
          return
        end

        @review_message = nil
        out_answers = Array(String).new(@answers.size, "")
        @answers.each_with_index do |a, i|
          out_answers[i] = a || ""
        end
        emit_answers(out_answers)
      end

      private def emit_answers(answers : Array(String)) : Nil
        result = {} of String => String
        answers.each_with_index do |a, i|
          next if a.nil? || a.empty?
          question = @questions[i]?
          next unless question
          result[question.question] = a
        end
        @on_answer.try(&.call(result))
        hide
      end

      # ── Render ──────────────────────────────────────────────────────

      def render(width : Int32) : Array(String)
        return [] of String unless @visible
        submit_tab? ? render_submit_tab(width) : render_question_tab(width)
      end

      private def render_question_tab(width : Int32) : Array(String)
        qidx = current_question_index
        return render_submit_tab(width) unless qidx
        question = @questions[qidx]?
        return [] of String unless question

        accent = @theme.colors.primary
        dim = @theme.colors.dim
        success = @theme.colors.success
        render_width = {1, width}.max

        lines = [] of String
        lines << color("─" * render_width, accent)
        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold} question#{ANSI.reset}"
        lines << ""
        push_tabs(lines)
        lines << ""

        # Question header.
        lines << "#{ANSI.color(accent, nil)} ? #{question.question}#{ANSI.reset}"

        lines << "#{ANSI.color(dim, nil)}   Type your answer, then press Enter to save.#{ANSI.reset}" if editing_other?

        lines << ""
        options = display_options(qidx)
        cursor = current_cursor
        visible_start = compute_visible_start(cursor, options.size)
        visible_end = Math.min(options.size, visible_start + @max_visible_options)
        multi_set = @multi_selections[qidx]
        single_sel = @single_selections[qidx]

        (visible_start...visible_end).each do |i|
          opt = options[i]?
          next unless opt
          num = i + 1
          is_cursor = i == cursor
          is_other = opt[:kind] == :other
          is_selected = question.multi_select ? multi_set.includes?(i) : single_sel == i

          if editing_other? && is_cursor && is_other
            # Inline editing line: shows the Other label + live buffer + caret.
            prefix = question.multi_select ? "  [#{is_selected ? '✓' : ' '}] #{opt[:label]}: " : "  → [#{num}] #{opt[:label]}: "
            color = is_selected ? success : accent
            lines << "#{ANSI.color(color, nil)}#{ANSI.bold if is_selected}#{prefix}#{@other_input}█#{ANSI.reset}"
            next
          end

          label = render_option_label(qidx, opt, is_cursor)

          if question.multi_select
            checked = is_selected ? '✓' : ' '
            prefix = "  [#{checked}] "
            color = if is_selected && is_cursor
                      ANSI.bold
                      success
                    elsif is_selected
                      success
                    elsif is_cursor
                      accent
                    else
                      dim
                    end
          elsif is_selected && answered?(qidx)
            prefix = is_cursor ? "  → [#{num}] " : "    [#{num}] "
            color = success
          elsif is_cursor
            prefix = "  → [#{num}] "
            color = accent
          else
            prefix = "    [#{num}] "
            color = dim
          end

          bold_prefix = (is_selected && is_cursor) ? ANSI.bold : ""
          line = "#{ANSI.color(color, nil)}#{bold_prefix}#{prefix}#{label}#{ANSI.reset}"
          lines << line

          unless opt[:description].empty?
            lines << "#{ANSI.color(dim, nil)}        #{opt[:description]}#{ANSI.reset}"
          end
        end

        if visible_end < options.size || visible_start > 0
          lines << "#{ANSI.color(dim, nil)}   showing #{visible_start + 1}-#{visible_end} of #{options.size}#{ANSI.reset}"
        end

        lines << ""
        lines << build_question_hint(qidx)
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        lines
      end

      private def render_submit_tab(width : Int32) : Array(String)
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        text_color = @theme.colors.text
        warning = @theme.colors.warning
        render_width = {1, width}.max

        lines = [] of String
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold} question#{ANSI.reset}"
        lines << ""
        push_tabs(lines)
        lines << ""
        lines << "#{ANSI.color(text_color, nil)}#{ANSI.bold} #{REVIEW_TITLE}#{ANSI.reset}"

        review_warning = @review_message || (has_unanswered_questions? ? UNANSWERED_WARNING : nil)
        if review_warning
          lines << "#{ANSI.color(warning, nil)}  #{review_warning}#{ANSI.reset}"
        end
        lines << ""

        @questions.each_with_index do |question, i|
          answer = @answers[i]?
          lines << "#{ANSI.color(dim, nil)}  Q  #{question.question}#{ANSI.reset}"
          if answer && !answer.empty?
            lines << "#{ANSI.color(accent, nil)}  →  #{answer}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(dim, nil)}  →  #{NOT_ANSWERED}#{ANSI.reset}"
          end
        end

        lines << ""
        lines << "#{ANSI.color(text_color, nil)} #{SUBMIT_PROMPT}#{ANSI.reset}"
        lines << ""

        SUBMIT_ACTIONS.each_with_index do |label, i|
          num = i + 1
          if i == @submit_action_idx
            lines << "#{ANSI.color(accent, nil)}  → [#{num}] #{label}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(dim, nil)}    [#{num}] #{label}#{ANSI.reset}"
          end
        end

        lines << ""
        lines << build_submit_hint
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        lines
      end

      private def push_tabs(lines : Array(String)) : Nil
        dim = @theme.colors.dim
        success = @theme.colors.success

        tabs = [] of String
        @questions.each_with_index do |question, i|
          label = question.header.empty? ? "Q#{i + 1}" : question.header
          if i == @current_tab
            tabs << "#{ANSI.color(success, nil)}#{ANSI.bold} #{label} #{ANSI.reset}"
          elsif answered?(i)
            tabs << "#{ANSI.color(success, nil)}(✓) #{label}#{ANSI.reset}"
          else
            tabs << "#{ANSI.color(dim, nil)}(○) #{label}#{ANSI.reset}"
          end
        end

        submit_label = "Submit"
        if submit_tab?
          tabs << "#{ANSI.color(success, nil)}#{ANSI.bold} #{submit_label} #{ANSI.reset}"
        else
          tabs << "#{ANSI.color(dim, nil)} #{submit_label} #{ANSI.reset}"
        end

        lines << " #{tabs.join("  ")}"
      end

      private def build_question_hint(qidx : Int32) : String
        dim = @theme.colors.dim
        if editing_other?
          parts = ["type answer", "↵ save"]
          parts << "tab switch" if total_tabs > 1
          parts << "esc cancel"
          return "#{ANSI.color(dim, nil)}  #{parts.join("  ")}#{ANSI.reset}"
        end

        question = @questions[qidx]?
        return "#{ANSI.color(dim, nil)}  esc cancel#{ANSI.reset}" unless question

        option_count = Math.min(display_options(qidx).size, 9)
        number_hint = option_count <= 1 ? "1" : "1-#{option_count}"
        parts = ["↑↓ select", "#{number_hint} / ↵ #{question.multi_select ? "toggle" : "choose"}"]
        parts << "←/→/tab switch" if total_tabs > 1
        parts << "esc cancel"
        "#{ANSI.color(dim, nil)}  #{parts.join("  ")}#{ANSI.reset}"
      end

      private def build_submit_hint : String
        dim = @theme.colors.dim
        parts = ["↑↓ select", "1/2 choose", "↵ confirm"]
        parts << "←/→/tab switch" if total_tabs > 1
        parts << "esc cancel"
        "#{ANSI.color(dim, nil)}  #{parts.join("  ")}#{ANSI.reset}"
      end

      private def compute_visible_start(cursor : Int32, total : Int32) : Int32
        return 0 if total <= @max_visible_options
        half = @max_visible_options // 2
        max = {0, total - @max_visible_options}.max
        {0, Math.min(cursor - half, max)}.max
      end

      # ── Helpers ─────────────────────────────────────────────────────

      private def total_tabs : Int32
        @questions.size + 1
      end

      private def submit_tab_index : Int32
        @questions.size
      end

      private def submit_tab? : Bool
        @current_tab == submit_tab_index
      end

      private def editing_other? : Bool
        @editing_other && !submit_tab?
      end

      private def current_question_index : Int32?
        submit_tab? ? nil : @current_tab
      end

      private def current_cursor : Int32
        qidx = current_question_index
        return 0 unless qidx
        @cursors[qidx]? || 0
      end

      # Display options = preset options + synthetic "Other".
      private def display_options(qidx : Int32) : Array({label: String, description: String, kind: Symbol})
        question = @questions[qidx]?
        return [] of ({label: String, description: String, kind: Symbol}) unless question
        opts = question.options.map do |opt|
          {label: opt.label, description: opt.description, kind: :preset}
        end
        opts << {label: DEFAULT_OTHER, description: "", kind: :other}
        opts
      end

      private def other_option_index(qidx : Int32) : Int32
        q = @questions[qidx]?
        q ? q.options.size : 0
      end

      private def other_option?(qidx : Int32, option_idx : Int32) : Bool
        option_idx == other_option_index(qidx)
      end

      private def render_option_label(qidx : Int32, opt, is_cursor : Bool) : String
        return opt[:label] unless opt[:kind] == :other

        value = other_draft_value(qidx)
        if editing_other? && is_cursor
          return "#{opt[:label]}: #{value}█"
        end
        value.empty? ? opt[:label] : "#{opt[:label]}: #{value}"
      end

      private def other_draft_value(qidx : Int32) : String
        @other_drafts[qidx]? || @committed_other[qidx]? || ""
      end

      private def sync_other_draft(qidx : Int32) : Nil
        @other_drafts[qidx] = @other_input
      end

      private def answered?(qidx : Int32) : Bool
        a = @answers[qidx]?
        !a.nil? && !a.empty?
      end

      private def has_unanswered_questions? : Bool
        @questions.each_with_index { |_, i| return true unless answered?(i) }
        false
      end

      private def color(text : String, code : Int32) : String
        ANSI.color(code, nil) + text + ANSI.reset
      end
    end
  end
end
