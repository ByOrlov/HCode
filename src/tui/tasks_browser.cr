module Hcode
  module TUI
    # Full port of the TS `TasksBrowserApp`
    # (`apps/kimi-code/src/tui/components/dialogs/tasks-browser.ts`).
    #
    # Full-screen 3-pane takeover for browsing background tasks:
    #   - Left column: task list (id, status, description).
    #   - Right top: detail panel (task id, status, description, timing, etc.).
    #   - Right bottom: tail output preview.
    #
    # Framed by a header (counts, filter state) and a footer (key hint /
    # inline stop-confirm). Mounted as a modal dialog in the main TUI; input
    # routing switches over while visible. Mirrors the TS layout primitives
    # (renderFrame, fitExactly, padToWidth) so the visual output matches.
    class TasksBrowser
      MIN_WIDTH               =    48
      MIN_HEIGHT              =    10
      LIST_COL_MIN            =    28
      LIST_COL_MAX            =    44
      LIST_COL_RATIO          =  0.32
      STOP_CONFIRM_TIMEOUT_MS = 5_000

      # Filter for the task list. :active = only running tasks, :all = everything.
      enum Filter
        All
        Active

        def to_s : String
          case self
          in All    then "all"
          in Active then "active"
          end
        end
      end

      getter? visible : Bool = false
      getter selected_index : Int32 = 0
      getter filter : Filter = Filter::Active
      setter filter : Filter
      @sorted_visible : Array(Tools::AgentTaskInfo) = [] of Tools::AgentTaskInfo
      @list_scroll : Int32 = 0
      @pending_stop_task_id : String?
      @pending_stop_until : Time::Span?
      @flash_message : String?
      @tail_output : String?
      @tail_loading : Bool = false
      @rows : Int32 = 24

      @theme : Theme
      @on_select : (String -> Nil)?
      @on_toggle_filter : (-> Nil)?
      @on_refresh : (-> Nil)?
      @on_stop_confirmed : (String -> Nil)?
      @on_stop_ignored : (String -> Nil)?
      @on_open_output : (String -> Nil)?
      @on_cancel : (-> Nil)?
      @on_fetch_tasks : (-> Array(Tools::AgentTaskInfo))?

      def initialize(@theme : Theme = Theme.dark)
      end

      # Show the browser. The `on_fetch_tasks` callback is the data source —
      # invoked on each refresh to pull the current task list from the agent.
      def show(on_fetch_tasks : -> Array(Tools::AgentTaskInfo),
               on_select : String -> Nil,
               on_toggle_filter : (-> Nil)? = nil,
               on_refresh : (-> Nil)? = nil,
               on_stop_confirmed : (String -> Nil)? = nil,
               on_stop_ignored : (String -> Nil)? = nil,
               on_open_output : (String -> Nil)? = nil,
               on_cancel : (-> Nil)? = nil,
               initial_filter : Filter = Filter::Active) : Nil
        @on_fetch_tasks = on_fetch_tasks
        @filter = initial_filter
        @on_select = on_select
        @on_toggle_filter = on_toggle_filter
        @on_refresh = on_refresh
        @on_stop_confirmed = on_stop_confirmed
        @on_stop_ignored = on_stop_ignored
        @on_open_output = on_open_output
        @on_cancel = on_cancel
        @visible = true
        @selected_index = 0
        @list_scroll = 0
        @pending_stop_task_id = nil
        @pending_stop_until = nil
        @flash_message = nil
        refresh_tasks
      end

      def hide : Nil
        @visible = false
      end

      property rows : Int32
      property tail_output : String?
      property? tail_loading : Bool = false
      property flash_message : String?

      # Re-fetch the task list from the callback, re-sort, and re-sync the
      # selected index. Called on show + on `r` (refresh) and on `tab` (filter
      # toggle, which changes which tasks are visible).
      def refresh_tasks : Nil
        return unless cb = @on_fetch_tasks
        tasks = cb.call
        @sorted_visible = visible_tasks(tasks, @filter).sort { |a, b| compare_tasks(a, b) }
        sync_selection_from_props

        # Auto-clear the pending stop confirmation if the task went terminal.
        if (pid = @pending_stop_task_id) && (task = tasks.find { |t| t.task_id == pid })
          if task.status.terminal?
            clear_pending_stop
          end
        end
      end

      private def sync_selection_from_props : Nil
        if @sorted_visible.empty?
          @selected_index = 0
          @list_scroll = 0
          return
        end
        if @selected_index >= @sorted_visible.size
          @selected_index = @sorted_visible.size - 1
        end
      end

      private def clear_pending_stop : Nil
        @pending_stop_task_id = nil
        @pending_stop_until = nil
      end

      private def pending_stop_active? : Bool
        return false if @pending_stop_task_id.nil?
        return false unless limit = @pending_stop_until
        Time.monotonic > limit ? (clear_pending_stop; false) : true
      end

      private def emit_select : Nil
        task = @sorted_visible[@selected_index]?
        @on_select.try(&.call(task.task_id)) if task
      end

      # ── Input ───────────────────────────────────────────────────────

      def handle_input(key : KeyEvent) : Nil
        # First, drain the pending stop confirmation.
        if pending_stop_active?
          if key.key.char?
            ch = key.char.not_nil!
            case ch
            when 'y', 'Y'
              task_id = @pending_stop_task_id
              clear_pending_stop
              if t = task_id
                @on_stop_confirmed.try(&.call(t))
              end
              return
            end
          end
          clear_pending_stop
          return
        end

        case key.key
        when .escape?
          @on_cancel.try(&.call)
          return
        when .up?
          move(-1)
          return
        when .down?
          move(1)
          return
        when .tab?
          @on_toggle_filter.try(&.call)
          return
        when .enter?
          open_output
          return
        end

        if key.key.char?
          ch = key.char.not_nil!
          case ch
          when 'q', 'Q'
            @on_cancel.try(&.call)
          when 'k'
            move(-1)
          when 'j'
            move(1)
          when 'r', 'R'
            @on_refresh.try(&.call)
          when 's', 'S'
            request_stop
          when 'o', 'O'
            open_output
          end
        end
      end

      private def move(delta : Int32) : Nil
        return if @sorted_visible.empty?
        @selected_index = (@selected_index + delta).clamp(0, @sorted_visible.size - 1)
        emit_select
      end

      private def request_stop : Nil
        task = @sorted_visible[@selected_index]?
        return unless task
        if task.status.terminal?
          @on_stop_ignored.try(&.call(task.task_id))
          return
        end
        @pending_stop_task_id = task.task_id
        @pending_stop_until = Time.monotonic + STOP_CONFIRM_TIMEOUT_MS.milliseconds
      end

      private def open_output : Nil
        task = @sorted_visible[@selected_index]?
        @on_open_output.try(&.call(task.task_id)) if task
      end

      # ── Render ──────────────────────────────────────────────────────

      def render(width : Int32) : Array(String)
        return [] of String unless @visible
        rows_now = Math.max(1, @rows)
        if width < MIN_WIDTH || rows_now < MIN_HEIGHT
          return render_too_small(width, rows_now)
        end

        header = render_header(width)
        footer = render_footer(width)
        body_height = rows_now - 2

        list_width = Math.max(
          LIST_COL_MIN,
          Math.min(LIST_COL_MAX, (width.to_f * LIST_COL_RATIO).to_i32)
        )
        right_width = width - list_width

        list_frame = render_list_frame(list_width, body_height)
        right_frames = render_right_stack(right_width, body_height)

        lines = [header]
        body_height.times do |i|
          left = list_frame[i]? || " " * list_width
          right = right_frames[i]? || " " * right_width
          lines << left + right
        end
        lines << footer
        lines
      end

      # ── header / footer ─────────────────────────────────────────────

      private def render_header(width : Int32) : String
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        success = @theme.colors.success
        error_c = @theme.colors.error

        title = "#{ANSI.color(accent, nil)}#{ANSI.bold} TASK BROWSER #{ANSI.reset}"
        filter_text = "#{ANSI.color(dim, nil)} filter=#{@filter == Filter::All ? "ALL" : "ACTIVE"} #{ANSI.reset}"

        counts = count_by_status(@sorted_visible)
        segments = String::Builder.new
        segments << title
        segments << filter_text
        if counts[:running] > 0
          segments << "#{ANSI.color(success, nil)} #{counts[:running]} running #{ANSI.reset}"
        end
        if counts[:completed] > 0
          segments << "#{ANSI.color(dim, nil)} #{counts[:completed]} completed #{ANSI.reset}"
        end
        if counts[:failed] > 0
          segments << "#{ANSI.color(error_c, nil)} #{counts[:failed]} interrupted #{ANSI.reset}"
        end
        segments << "#{ANSI.color(dim, nil)} #{@sorted_visible.size} total #{ANSI.reset}"
        fit_exactly(segments.to_s, width)
      end

      private def render_footer(width : Int32) : String
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        warning = @theme.colors.warning
        text_c = @theme.colors.text

        if pending_stop_active?
          task_id = @pending_stop_task_id || ""
          line = " #{ANSI.color(warning, nil)}#{ANSI.bold}Stop#{ANSI.reset} #{ANSI.color(text_c, nil)}#{task_id}#{ANSI.reset}? " \
                 "#{ANSI.color(accent, nil)}#{ANSI.bold}Y#{ANSI.reset} #{ANSI.color(dim, nil)}confirm  " \
                 "#{ANSI.color(accent, nil)}#{ANSI.bold}N#{ANSI.reset}#{ANSI.color(dim, nil)}/#{ANSI.reset}" \
                 "#{ANSI.color(accent, nil)}#{ANSI.bold}esc#{ANSI.reset} #{ANSI.color(dim, nil)}cancel "
          return fit_exactly(line, width)
        end

        parts = [
          " #{ANSI.color(accent, nil)}#{ANSI.bold}↑↓#{ANSI.reset} #{ANSI.color(dim, nil)}select",
          "#{ANSI.color(accent, nil)}#{ANSI.bold}Enter/O#{ANSI.reset} #{ANSI.color(dim, nil)}output",
          "#{ANSI.color(accent, nil)}#{ANSI.bold}S#{ANSI.reset} #{ANSI.color(dim, nil)}stop",
          "#{ANSI.color(accent, nil)}#{ANSI.bold}R#{ANSI.reset} #{ANSI.color(dim, nil)}refresh",
          "#{ANSI.color(accent, nil)}#{ANSI.bold}Tab#{ANSI.reset} #{ANSI.color(dim, nil)}filter",
          "#{ANSI.color(accent, nil)}#{ANSI.bold}Q/Esc#{ANSI.reset} #{ANSI.color(dim, nil)}cancel ",
        ]
        left = parts.join("  ")
        if (flash = @flash_message) && !flash.empty?
          flash_styled = "#{ANSI.color(warning, nil)} #{flash} #{ANSI.reset}"
          total = left.size + flash_styled.size
          return total <= width ? left + (" " * (width - total)) + flash_styled : fit_exactly(left, width)
        end
        fit_exactly(left, width)
      end

      # ── frame primitive ─────────────────────────────────────────────

      # Render a framed box `┌─ Title ─┐` / `│ inner │` / `└──┘`. Result is
      # exactly `width × height` cells. `content` lines are padded/truncated
      # to `inner_width = width - 2`.
      private def render_frame(title : String, content : Array(String), width : Int32, height : Int32) : Array(String)
        if height < 2 || width < 4
          return Array.new(height) { " " * width }
        end
        accent = @theme.colors.primary
        inner_width = width - 2
        inner_height = height - 2

        title_styled = "#{ANSI.bold}#{title}#{ANSI.reset}"
        title_segment = "─ #{title_styled} "
        title_segment_width = title_segment.size
        remaining_dashes = {0, inner_width - title_segment_width}.max

        if !title.empty? && title_segment_width <= inner_width
          top_mid = "#{ANSI.color(accent, nil)}─ #{ANSI.reset}#{title_styled} #{ANSI.color(accent, nil)}#{"─" * remaining_dashes}#{ANSI.reset}"
        else
          top_mid = "#{ANSI.color(accent, nil)}#{"─" * inner_width}#{ANSI.reset}"
        end
        top = "#{ANSI.color(accent, nil)}┌#{ANSI.reset}#{top_mid}#{ANSI.color(accent, nil)}┐#{ANSI.reset}"
        bottom = "#{ANSI.color(accent, nil)}└#{"─" * inner_width}┘#{ANSI.reset}"

        lines = [top]
        inner_height.times do |i|
          inner = content[i]? || ""
          lines << "#{ANSI.color(accent, nil)}│#{ANSI.reset}#{fit_exactly(inner, inner_width)}#{ANSI.color(accent, nil)}│#{ANSI.reset}"
        end
        lines << bottom
        lines
      end

      # ── left: task list ─────────────────────────────────────────────

      private def render_list_frame(width : Int32, height : Int32) : Array(String)
        title = "Tasks [#{@filter}]"
        inner_height = {0, height - 2}.max

        if @sorted_visible.empty?
          empty = @filter.active? ? "No active tasks. Tab = show all." : "No background tasks in this session."
          lines = ["#{ANSI.color(@theme.colors.dim, nil)}#{empty}#{ANSI.reset}"]
          while lines.size < inner_height
            lines << ""
          end
          return render_frame(title, lines, width, height)
        end

        adjust_scroll(inner_height)
        start = @list_scroll
        window = @sorted_visible[start, {inner_height, @sorted_visible.size - start}.min]? || [] of Tools::AgentTaskInfo
        inner_width = width - 2

        lines = [] of String
        window.each_with_index do |task, vi|
          index = start + vi
          lines << render_list_row(task, index == @selected_index, inner_width)
        end
        while lines.size < inner_height
          lines << ""
        end
        render_frame(title, lines, width, height)
      end

      private def render_list_row(task : Tools::AgentTaskInfo, selected : Bool, inner_width : Int32) : String
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        text_c = @theme.colors.text

        pointer = selected ? "▶ " : "  "
        pointer_styled = "#{ANSI.color(selected ? accent : dim, nil)}#{pointer}#{ANSI.reset}"

        id_text = selected ? "#{ANSI.bold}#{task.task_id}#{ANSI.reset}" : task.task_id
        id_pad = " " * {0, 17 - task.task_id.size}.max

        status_label = status_label_for(task.status)
        status_badge = "#{ANSI.color(status_color(task.status), nil)}#{status_label}#{ANSI.reset}"

        prefix = "#{pointer_styled}#{id_text}#{id_pad} #{status_badge}"
        prefix_width = prefix.size
        desc_budget = {0, inner_width - prefix_width - 1}.max
        return fit_exactly(prefix, inner_width) if desc_budget < 4

        description = single_line(task.description)
        description = single_line(task.command || "") if description.empty?
        description = "(no description)" if description.empty?
        desc = truncate_to_width(description, desc_budget)
        fit_exactly("#{prefix} #{ANSI.color(text_c, nil)}#{desc}#{ANSI.reset}", inner_width)
      end

      private def adjust_scroll(visible_rows : Int32) : Nil
        if visible_rows <= 0
          @list_scroll = 0
          return
        end
        if @selected_index < @list_scroll
          @list_scroll = @selected_index
        elsif @selected_index >= @list_scroll + visible_rows
          @list_scroll = @selected_index - visible_rows + 1
        end
        max_scroll = {0, @sorted_visible.size - visible_rows}.max
        @list_scroll = @list_scroll.clamp(0, max_scroll)
      end

      # ── right: detail + preview ─────────────────────────────────────

      private def render_right_stack(width : Int32, height : Int32) : Array(String)
        detail_height = Math.max(8, Math.min((height * 0.4).to_i32, height - 5))
        preview_height = height - detail_height
        render_detail_frame(width, detail_height) + render_preview_frame(width, preview_height)
      end

      private def render_detail_frame(width : Int32, height : Int32) : Array(String)
        inner_height = {0, height - 2}.max
        dim = @theme.colors.dim
        text_c = @theme.colors.text

        task = @sorted_visible[@selected_index]?
        if task.nil?
          lines = ["#{ANSI.color(dim, nil)}Select a task from the list.#{ANSI.reset}"]
          while lines.size < inner_height
            lines << ""
          end
          return render_frame("Detail", lines, width, height)
        end

        lines = [] of String
        lines << "#{ANSI.color(dim, nil)}#{label_pad("Task ID:")}#{ANSI.reset}#{ANSI.color(text_c, nil)}#{task.task_id}#{ANSI.reset}"
        lines << "#{ANSI.color(dim, nil)}#{label_pad("Status:")}#{ANSI.reset}#{ANSI.color(status_color(task.status), nil)}#{status_label_for(task.status)}#{ANSI.reset}"
        lines << "#{ANSI.color(dim, nil)}#{label_pad("Description:")}#{ANSI.reset}#{ANSI.color(text_c, nil)}#{single_line(task.description)}#{ANSI.reset}"

        if cmd = task.command
          if single_line(cmd) != single_line(task.description)
            lines << "#{ANSI.color(dim, nil)}#{label_pad("Command:")}#{ANSI.reset}#{ANSI.color(text_c, nil)}#{single_line(cmd)}#{ANSI.reset}"
          end
        end

        timing = if task.status.running?
                   "running #{format_relative_time(task.started_at)}"
                 elsif e = task.ended_at
                   "finished #{format_relative_time(e)}"
                 else
                   ""
                 end
        unless timing.empty?
          lines << "#{ANSI.color(dim, nil)}#{label_pad("Time:")}#{ANSI.reset}#{ANSI.color(dim, nil)}#{timing}#{ANSI.reset}"
        end

        if pid = task.pid
          if pid > 0
            lines << "#{ANSI.color(dim, nil)}#{label_pad("Pid:")}#{ANSI.reset}#{ANSI.color(dim, nil)}#{pid}#{ANSI.reset}"
          end
        end

        if ec = task.exit_code
          lines << "#{ANSI.color(dim, nil)}#{label_pad("Exit code:")}#{ANSI.reset}#{ANSI.color(dim, nil)}#{ec}#{ANSI.reset}"
        end

        if sr = task.stop_reason
          unless sr.empty?
            lines << "#{ANSI.color(dim, nil)}#{label_pad("Reason:")}#{ANSI.reset}#{ANSI.color(dim, nil)}#{sr}#{ANSI.reset}"
          end
        end

        while lines.size < inner_height
          lines << ""
        end
        render_frame("Detail", lines, width, height)
      end

      private def render_preview_frame(width : Int32, height : Int32) : Array(String)
        inner_height = {0, height - 2}.max
        dim = @theme.colors.dim

        task = @sorted_visible[@selected_index]?
        if task.nil?
          lines = ["#{ANSI.color(dim, nil)}No task selected.#{ANSI.reset}"]
          while lines.size < inner_height
            lines << ""
          end
          return render_frame("Preview Output", lines, width, height)
        end

        body = if @tail_loading
                 "[loading…]"
               elsif (t = @tail_output) && !t.empty?
                 t
               else
                 "[no output captured]"
               end

        raw_lines = body.split('\n')
        tail_lines = raw_lines.last(inner_height)
        styled = tail_lines.map { |line| "#{ANSI.color(dim, nil)}#{line}#{ANSI.reset}" }
        while styled.size < inner_height
          styled << ""
        end
        render_frame("Preview Output", styled, width, height)
      end

      # ── too-small ───────────────────────────────────────────────────

      private def render_too_small(width : Int32, rows : Int32) : Array(String)
        lines = [] of String
        msg = "#{ANSI.color(@theme.colors.error, nil)}Terminal too small (need ≥ #{MIN_WIDTH} × #{MIN_HEIGHT})#{ANSI.reset}"
        lines << fit_exactly(msg, width)
        (rows - 1).times { lines << " " * width }
        lines
      end

      # ── helpers ─────────────────────────────────────────────────────

      private def visible_tasks(tasks : Array(Tools::AgentTaskInfo), filter : Filter) : Array(Tools::AgentTaskInfo)
        background_only = tasks.select { |t| t.detached != false }
        return background_only if filter.all?
        background_only.reject { |t| t.status.terminal? }
      end

      private def compare_tasks(a : Tools::AgentTaskInfo, b : Tools::AgentTaskInfo) : Int32
        a_term = a.status.terminal?
        b_term = b.status.terminal?
        return a_term ? 1 : -1 if a_term != b_term
        return a.started_at <=> b.started_at unless a_term
        a_end = a.ended_at || a.started_at
        b_end = b.ended_at || b.started_at
        b_end <=> a_end
      end

      private def count_by_status(tasks : Array(Tools::AgentTaskInfo)) : Hash(Symbol, Int32)
        counts = {:running => 0, :completed => 0, :failed => 0}
        tasks.each do |t|
          case t.status
          when .running?
            counts[:running] += 1
          when .completed?
            counts[:completed] += 1
          when .failed?, .timed_out?, .killed?, .lost?
            counts[:failed] += 1
          end
        end
        counts
      end

      private def status_label_for(status : Tools::AgentTaskStatus) : String
        case status
        when .running?   then "running"
        when .completed? then "completed"
        when .failed?    then "failed"
        when .timed_out? then "timed out"
        when .killed?    then "killed"
        when .lost?      then "lost"
        else                  "unknown"
        end
      end

      private def status_color(status : Tools::AgentTaskStatus) : Int32
        case status
        when .running?   then @theme.colors.success
        when .completed? then @theme.colors.dim
        else                  @theme.colors.error
        end
      end

      private def single_line(text : String) : String
        text.gsub(/\s+/, " ").strip
      end

      private def label_pad(text : String) : String
        text.ljust(14)
      end

      # Truncate `line` so its visible width ≤ `width`, appending `…` if cut.
      private def truncate_to_width(line : String, width : Int32) : String
        return line if line.size <= width
        return "" if width <= 0
        return "…" if width == 1
        "#{line[0...(width - 1)]}…"
      end

      # Pad/truncate `line` to exactly `width` visible cells.
      private def fit_exactly(line : String, width : Int32) : String
        s = line
        s = truncate_to_width(s, width) if s.size > width
        return s if s.size == width
        s + (" " * (width - s.size))
      end

      private def format_relative_time(ts : Int64) : String
        return "" if ts <= 0
        diff_sec = (Time.utc.to_unix - ts).to_i64
        diff_sec = 0 if diff_sec < 0
        return "just now" if diff_sec < 60
        minutes = diff_sec // 60
        return "#{minutes}m ago" if minutes < 60
        hours = minutes // 60
        return "#{hours}h ago" if hours < 24
        "#{hours // 24}d ago"
      end
    end
  end
end
