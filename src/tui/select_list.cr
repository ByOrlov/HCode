module H2code
  module TUI
    class SelectList
      property items : Array(String)
      property selected : Int32 = 0
      property? visible : Bool = false
      property title : String = ""
      # Maximum number of rows rendered at once. The list scrolls when there
      # are more items, keeping the selection always visible.
      property max_visible : Int32 = 8
      # When true, printable characters build a fuzzy filter query (see
      # `Fuzzy`) and Backspace trims it. Off by default so short fixed lists
      # (effort levels, themes) keep their plain up/down behavior.
      property? searchable : Bool = false
      # When set, filtering uses this predicate `(query, original index)`
      # instead of fuzzy label matching — used by the session picker to
      # filter by wire-log content. Matching items keep their original order.
      property content_filter : (String, Int32 -> Bool)? = nil
      # When true, query edits update `query` but skip immediate filtering;
      # the owner schedules an async search via `on_query_changed` and calls
      # `apply_filter` when it completes. Used by the session picker so
      # wire-log scans never block typing.
      property? deferred_filter : Bool = false
      # Notified after every query edit while `deferred_filter` is on.
      property on_query_changed : (String -> Nil)? = nil
      # The active search query (empty == no filtering).
      property query : String = ""
      @theme : Theme
      @scroll_offset : Int32 = 0
      # The query the current filter state was computed from. With a
      # deferred filter this tracks staleness for `flush_filter!`.
      @applied_query : String = ""
      # Maps a filtered-list position back to its index in `items`. Identity
      # `[0,1,2,...]` when the query is empty; otherwise sorted by fuzzy score.
      @filtered_indices : Array(Int32) = [] of Int32
      # Per original item index: matched character positions (for highlight),
      # or `nil` when the item is filtered out / query is empty.
      @match_positions : Array(Array(Int32)?) = [] of Array(Int32)?

      def initialize(@items : Array(String) = [] of String, @theme : Theme = Theme.dark)
        reset_filter
      end

      def show(title : String, items : Array(String)) : Nil
        @title = title
        @items = items
        @selected = 0
        @scroll_offset = 0
        @query = ""
        @applied_query = ""
        reset_filter
        @visible = true
      end

      def hide : Nil
        @visible = false
      end

      # Clears the search query and restores the full list. Returns whether a
      # query was actually cleared.
      def clear_query : Bool
        return false if @query.empty?
        @query = ""
        @applied_query = ""
        reset_filter
        @selected = 0
        @scroll_offset = 0
        true
      end

      # The string under the cursor in the filtered view.
      def current : String?
        item_at(@selected)
      end

      # Item shown at filtered-list position *pos* (after query filtering).
      def item_at(pos : Int32) : String?
        idx = @filtered_indices[pos]?
        return nil unless idx
        @items[idx]?
      end

      # Original (unfiltered) index of the item under the cursor. Callers that
      # map a selection back to a parallel array (e.g. session entries) must use
      # this instead of `selected` when `searchable?` can be on.
      def selected_original_index : Int32
        @filtered_indices[@selected]? || @selected
      end

      # Matched character positions for the item at filtered position *pos*
      # (original-text indices), or `nil` when nothing to highlight.
      def match_positions_at(pos : Int32) : Array(Int32)?
        orig = @filtered_indices[pos]?
        return nil unless orig
        @match_positions[orig]?
      end

      # Total number of items currently shown (after filtering).
      def filtered_size : Int32
        @filtered_indices.size
      end

      def handle_input(key : KeyEvent) : Bool
        return false unless @visible

        case key.key
        when .up?
          @selected = (@selected - 1 + filtered_size) % filtered_size if filtered_size > 0
          true
        when .down?
          @selected = (@selected + 1) % filtered_size if filtered_size > 0
          true
        when .enter?
          true
        when .escape?
          hide
          true
        when .backspace?
          return false unless @searchable
          if @query.empty?
            false
          else
            @query = @query.rchop
            query_edited
            true
          end
        when .char?
          return false unless @searchable
          c = key.char
          return false if c.nil? || c.control?
          @query += c.to_s
          query_edited
          true
        else
          false
        end
      end

      # Compute the visible window [start, count) and lazily adjust the
      # scroll offset so the selected row is always on screen.
      def visible_window : {Int32, Int32}
        size = filtered_size
        return {0, 0} if size == 0
        mv = {@max_visible, size}.min
        if @selected < @scroll_offset
          @scroll_offset = @selected
        elsif @selected >= @scroll_offset + mv
          @scroll_offset = {@selected - mv + 1, 0}.max
        end
        max_offset = {size - mv, 0}.max
        @scroll_offset = {@scroll_offset, max_offset}.min
        {@scroll_offset, mv}
      end

      # True when there are rows above the current viewport.
      def scrolled_up? : Bool
        _, _ = visible_window
        @scroll_offset > 0
      end

      # True when there are rows below the current viewport.
      def scrolled_down? : Bool
        start, count = visible_window
        start + count < filtered_size
      end

      # Rebuilds the identity mapping (no filtering). `apply_filter` recomputes
      # it from scratch whenever the query changes.
      private def reset_filter : Nil
        @filtered_indices = (0...@items.size).to_a
        @match_positions = Array.new(@items.size, nil.as(Array(Int32)?))
      end

      # Route a query edit: filter inline, or — when `deferred_filter` is
      # on — just notify the owner so it can debounce an async search.
      private def query_edited : Nil
        if @deferred_filter
          @on_query_changed.try(&.call(@query))
        else
          apply_filter
        end
      end

      # Apply the filter for an edit that happened while `deferred_filter`
      # is on (owner-driven async search); no-op when already current.
      def flush_filter! : Nil
        apply_filter unless @query == @applied_query
      end

      # Recompute `@filtered_indices` and the per-item match positions for the
      # current `@query`. With a `content_filter` the predicate decides what
      # stays (original order); otherwise items are sorted by fuzzy score.
      # The cursor snaps to the top.
      def apply_filter : Nil
        if @query.empty?
          reset_filter
          @selected = 0
          @scroll_offset = 0
          @applied_query = @query
          return
        end
        if filter = @content_filter
          @filtered_indices = (0...@items.size).select { |i| filter.call(@query, i) }
          @match_positions = Array.new(@items.size, nil.as(Array(Int32)?))
          @selected = 0
          @scroll_offset = 0
          # Only after a successful pass: an aborted (exception-raising)
          # filter run leaves the query marked unapplied so it is retried.
          @applied_query = @query
          return
        end
        ranked = Fuzzy.filter(@items, @query)
        @filtered_indices = ranked.map(&.[0])
        positions = Array.new(@items.size, nil.as(Array(Int32)?))
        ranked.each do |idx, res|
          positions[idx] = res.positions
        end
        @match_positions = positions
        @selected = 0
        @scroll_offset = 0
        @applied_query = @query
      end
    end
  end
end
