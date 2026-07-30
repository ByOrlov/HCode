module Hcode
  module TUI
    # Interactive plan-review dialog surfaced by `ExitPlanMode` in manual / yolo
    # permission modes. Mirrors the JS `PlanBoxComponent` + approval-runtime
    # review surface: renders the finalized plan, optional approach options, and
    # the host's Approve / Revise / Reject & Exit / Cancel controls. The host
    # (App) owns the blocking channel; this component only emits a
    # `Tools::PlanReviewResult` through a callback and hides.
    class PlanReviewDialog
      ACTIONS = ["Approve", "Revise", "Reject & Exit", "Cancel"]

      @plan : String = ""
      @path : String?
      @options : Array(Tools::PlanOption)?
      @theme : Theme
      @markdown : Markdown
      @on_result : (Tools::PlanReviewResult -> Nil)?

      getter? visible : Bool = false

      # 0-based cursor into ACTIONS.
      @action_idx : Int32 = 0
      # Selected option index (nil = none). Only meaningful when @options set.
      @option_cursor : Int32 = 0
      @option_selected : Int32? = nil
      # Inline feedback buffer while editing in Revise mode.
      @editing_feedback : Bool = false
      @feedback : String = ""

      def initialize(@theme : Theme = Theme.dark)
        @markdown = Markdown.new(@theme)
      end

      def show(plan : String, path : String?, options : Array(Tools::PlanOption)?,
               on_result : Tools::PlanReviewResult -> Nil) : Nil
        @plan = plan
        @path = path
        @options = options && !options.empty? ? options : nil
        @on_result = on_result
        @action_idx = 0
        @option_cursor = 0
        @option_selected = nil
        @editing_feedback = false
        @feedback = ""
        @visible = true
      end

      def hide : Nil
        @visible = false
      end

      # ── Input ───────────────────────────────────────────────────────

      def handle_input(key : KeyEvent) : Nil
        if @editing_feedback
          handle_feedback_input(key)
          return
        end

        case key.key
        when .escape?, .ctrl_c?, .ctrl_d?
          emit(Tools::PlanReviewDecision::Dismissed)
          return
        when .up?
          @action_idx = (@action_idx - 1 + ACTIONS.size) % ACTIONS.size
          return
        when .down?
          @action_idx = (@action_idx + 1) % ACTIONS.size
          return
        when .left?
          move_option(-1)
          return
        when .right?
          move_option(1)
          return
        when .enter?
          execute_action(@action_idx)
          return
        end

        # Number-key hotkeys for actions (1-4).
        if key.key.char? && (ch = key.char)
          if ch.ascii_number?
            num = ch.to_i - 1
            if num >= 0 && num < ACTIONS.size
              @action_idx = num
              execute_action(num)
              return
            end
          end
        end
      end

      private def handle_feedback_input(key : KeyEvent) : Nil
        case key.key
        when .escape?
          @editing_feedback = false
          @feedback = ""
          return
        when .enter?
          @editing_feedback = false
          emit(Tools::PlanReviewDecision::Revise, @feedback)
          return
        when .backspace?
          @feedback = @feedback.rchop
          return
        when .tab?
          @editing_feedback = false
          emit(Tools::PlanReviewDecision::Revise, @feedback)
          return
        end

        if key.key.char? && (ch = key.char)
          return if ch.whitespace? && ch != ' '
          @feedback += ch.to_s
        end
      end

      private def move_option(delta : Int32) : Nil
        opts = @options
        return unless opts
        total = opts.size
        @option_cursor = (@option_cursor + delta + total) % total
      end

      private def execute_action(idx : Int32) : Nil
        case idx
        when 0 # Approve
          label = @options.try { |opts| opts[@option_cursor]?.try(&.label) }
          emit(Tools::PlanReviewDecision::Approve, selected_label: label)
        when 1 # Revise
          @editing_feedback = true
          @feedback = ""
        when 2 # Reject & Exit
          emit(Tools::PlanReviewDecision::RejectAndExit)
        when 3 # Cancel
          emit(Tools::PlanReviewDecision::Dismissed)
        end
      end

      private def emit(decision : Tools::PlanReviewDecision,
                       feedback : String = "",
                       selected_label : String? = nil) : Nil
        sel = selected_label || @options.try { |opts| opts[@option_cursor]?.try(&.label) if decision.approve? }
        result = Tools::PlanReviewResult.new(decision, sel, feedback)
        hide
        @on_result.try(&.call(result))
      end

      # ── Render ──────────────────────────────────────────────────────

      def render(width : Int32) : Array(String)
        return [] of String unless @visible
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        text_color = @theme.colors.text
        warning = @theme.colors.warning
        render_width = {1, width}.max

        lines = [] of String
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        title = " plan review"
        if p = @path
          title += ": #{File.basename(p)}"
        end
        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold}#{title}#{ANSI.reset}"
        lines << ""

        # Plan body (markdown-rendered, clamped to keep the dialog readable).
        body_width = {20, render_width - 4}.max
        body_lines = render_plan_body(@plan, body_width)
        if body_lines.empty?
          lines << "#{ANSI.color(dim, nil)}   (empty plan)#{ANSI.reset}"
        else
          body_lines.first(40).each do |bl|
            lines << "  #{bl}"
          end
        end
        lines << ""

        # Options (if any).
        if opts = @options
          lines << "#{ANSI.color(text_color, nil)}#{ANSI.bold} Approaches:#{ANSI.reset}"
          opts.each_with_index do |opt, i|
            cursor = i == @option_cursor
            selected = i == @option_selected
            marker = selected ? "●" : "○"
            color = cursor ? accent : dim
            bold = cursor ? ANSI.bold : ""
            lines << "#{ANSI.color(color, nil)}  #{bold}#{marker} #{opt.label}#{ANSI.reset}"
            unless opt.description.empty?
              lines << "#{ANSI.color(dim, nil)}      #{opt.description}#{ANSI.reset}"
            end
          end
          lines << ""
        end

        # Feedback editing line.
        if @editing_feedback
          lines << "#{ANSI.color(warning, nil)}#{ANSI.bold} Feedback:#{@feedback}█#{ANSI.reset}"
          lines << "#{ANSI.color(dim, nil)}   type feedback · Enter submit · Esc cancel#{ANSI.reset}"
          lines << ""
        end

        # Actions.
        ACTIONS.each_with_index do |label, i|
          num = i + 1
          if i == @action_idx && !@editing_feedback
            lines << "#{ANSI.color(accent, nil)}  → [#{num}] #{label}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(dim, nil)}    [#{num}] #{label}#{ANSI.reset}"
          end
        end

        lines << ""
        hint = @editing_feedback ? "type feedback · Enter submit · Esc cancel" :
          "↑↓ action · ←/→ option · 1-4 / Enter confirm · Esc cancel"
        lines << "#{ANSI.color(dim, nil)}  #{hint}#{ANSI.reset}"
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        lines
      end

      private def render_plan_body(plan : String, width : Int32) : Array(String)
        rendered = @markdown.render(plan, width)
        rendered.empty? ? [plan.strip] of String : rendered
      end
    end
  end
end
