module H2code
  module TUI
    # Interactive plan-review dialog surfaced by `ExitPlanMode` in manual / yolo
    # permission modes. Mirrors the JS `PlanBoxComponent` + approval-runtime
    # review surface: renders the finalized plan, optional approach options, and
    # the host's Approve / Revise / Reject & Exit / Cancel controls. The host
    # (App) owns the blocking channel; this component only emits a
    # `Tools::PlanReviewResult` through a callback and hides.
    class PlanReviewDialog
      ACTIONS = ["View full plan", "Approve", "Revise", "Reject & Exit", "Cancel"]
      # Max plan-body lines rendered inline in the review dialog; longer plans
      # are truncated with a header/footer indicator so the user knows to open
      # the full viewer.
      PREVIEW_LINES = 40

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

      # Full-plan viewer: a full-screen scrollable takeover of the plan body.
      # Entered via the "View full plan" action; Esc/q returns to the action
      # list. `@full_lines` is the markdown-rendered plan (cached when the
      # viewer is entered via `render_full_lines`); `@full_scroll` is the top
      # line index into it.
      getter? viewing_full : Bool = false
      @full_lines : Array(String) = [] of String
      @full_scroll : Int32 = 0
      # Terminal height, set by the App before each render/input so the viewer
      # knows its viewport. Mirrors TasksBrowser#rows=.
      property rows : Int32 = 24

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
        @viewing_full = false
        @full_scroll = 0
        @visible = true
      end

      def hide : Nil
        @visible = false
        @viewing_full = false
      end

      # ── Input ───────────────────────────────────────────────────────

      def handle_input(key : KeyEvent) : Nil
        if @viewing_full
          handle_full_view_input(key)
          return
        end

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

      private def handle_full_view_input(key : KeyEvent) : Nil
        case key.key
        when .escape?
          @viewing_full = false
          return
        when .up?
          @full_scroll = (@full_scroll - 1).clamp(0, full_max_scroll)
          return
        when .down?
          @full_scroll = (@full_scroll + 1).clamp(0, full_max_scroll)
          return
        when .page_up?
          @full_scroll = (@full_scroll - full_viewport).clamp(0, full_max_scroll)
          return
        when .page_down?
          @full_scroll = (@full_scroll + full_viewport).clamp(0, full_max_scroll)
          return
        when .home?
          @full_scroll = 0
          return
        when .end?
          @full_scroll = full_max_scroll
          return
        end

        if key.key.char? && (ch = key.char)
          case ch
          when 'q', 'Q'
            @viewing_full = false
          when 'k'
            @full_scroll = (@full_scroll - 1).clamp(0, full_max_scroll)
          when 'j'
            @full_scroll = (@full_scroll + 1).clamp(0, full_max_scroll)
          end
        end
      end

      # Visible rows available for the plan body inside the full-screen viewer.
      private def full_viewport : Int32
        {1, @rows - 4}.max # header (2) + footer hint (1) + trailing pad (1)
      end

      private def full_max_scroll : Int32
        {0, @full_lines.size - full_viewport}.max
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
        when 0 # View full plan
          render_full_lines
          @full_scroll = 0
          @viewing_full = true
        when 1 # Approve
          label = @options.try { |opts| opts[@option_cursor]?.try(&.label) }
          emit(Tools::PlanReviewDecision::Approve, selected_label: label)
        when 2 # Revise
          @editing_feedback = true
          @feedback = ""
        when 3 # Reject & Exit
          emit(Tools::PlanReviewDecision::RejectAndExit)
        when 4 # Cancel
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
        return render_full(width) if @viewing_full
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
          truncated = body_lines.size > PREVIEW_LINES
          if truncated
            lines << "#{ANSI.color(dim, nil)}  First #{PREVIEW_LINES} lines of a PLAN#{ANSI.reset}"
          end
          body_lines.first(PREVIEW_LINES).each do |bl|
            lines << "  #{bl}"
          end
          if truncated
            lines << "#{ANSI.color(dim, nil)}  #{"." * 11}#{ANSI.reset}"
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
        hint = @editing_feedback ? "type feedback · Enter submit · Esc cancel" : "↑↓ action · ←/→ option · 1-5 / Enter confirm · Esc cancel"
        lines << "#{ANSI.color(dim, nil)}  #{hint}#{ANSI.reset}"
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        lines
      end

      # Full-screen plan viewer. Rendered as a full-screen takeover by the App
      # (mirrors TasksBrowser): a header (path + line counter), the scrollable
      # markdown-rendered plan body, and a footer key-hint. The body is cached
      # in `@full_lines` (built once on entering the viewer via
      # `render_full_lines`) so scrolling stays O(viewport).
      private def render_full(width : Int32) : Array(String)
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        render_width = {1, width}.max
        rows_now = {1, @rows}.max

        lines = [] of String
        # Header: separator + title line.
        lines << "#{ANSI.color(accent, nil)}#{"─" * render_width}#{ANSI.reset}"
        title = " full plan"
        if p = @path
          title += ": #{File.basename(p)}"
        end
        total = @full_lines.size
        shown = {total, full_viewport}.min
        last_visible = {@full_scroll + shown, total}.min
        title += "  #{ANSI.color(dim, nil)}(#{last_visible}/#{total})#{ANSI.reset}"
        lines << "#{ANSI.color(accent, nil)}#{ANSI.bold}#{title}#{ANSI.reset}"

        viewport = full_viewport
        start = @full_scroll.clamp(0, full_max_scroll)
        window = @full_lines[start, {viewport, @full_lines.size - start}.min]? || [] of String
        window.each do |bl|
          lines << bl
        end
        # Pad the body up to the footer so short plans don't shift the layout.
        while lines.size < rows_now - 1
          lines << ""
        end

        # Footer hint.
        lines << "#{ANSI.color(dim, nil)}  ↑↓/j k scroll · PgUp/PgDn · Home/End · Esc/q back#{ANSI.reset}"
        lines
      end

      # Build (or rebuild) the cached full-plan lines. Called when entering the
      # viewer; body width tracks the terminal so wraps stay consistent while
      # scrolling.
      private def render_full_lines : Nil
        width = {20, @terminal_width - 2}.max
        @full_lines = render_plan_body(@plan, width)
      end

      # Terminal width for plan body wrapping. Set by the App alongside `rows`.
      @terminal_width : Int32 = 80

      def terminal_width=(v : Int32) : Nil
        @terminal_width = v
      end

      private def render_plan_body(plan : String, width : Int32) : Array(String)
        rendered = @markdown.render(plan, width)
        rendered.empty? ? [plan.strip] of String : rendered
      end
    end
  end
end
