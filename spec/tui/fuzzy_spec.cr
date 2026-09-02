require "../spec_helper"

# Verifies the fuzzy matcher: subsequence requirement, scoring/ranking quality,
# match-position reconstruction (for highlighting), and `SelectList` filtering.
describe H2code::TUI::Fuzzy do
  describe ".matches?" do
    it "matches a subsequence case-insensitively" do
      H2code::TUI::Fuzzy.matches?("g45", "glm-4.5").should be_true
      H2code::TUI::Fuzzy.matches?("G45", "glm-4.5").should be_true
    end

    it "rejects when chars are out of order or missing" do
      H2code::TUI::Fuzzy.matches?("54", "glm-4.5").should be_false
      H2code::TUI::Fuzzy.matches?("abc", "ab").should be_false
    end

    it "treats empty query as non-matching" do
      H2code::TUI::Fuzzy.matches?("", "anything").should be_false
    end
  end

  describe ".match (score + positions)" do
    it "returns matched positions in ascending order" do
      res = H2code::TUI::Fuzzy.match("g45", "glm-4.5")
      res.should_not be_nil
      res = res || raise "res should not be nil"
      res.positions.should eq([0, 4, 6])
      res.score.should be > 0
    end

    it "scores a prefix/word-boundary match higher than a scattered one" do
      prefix = (H2code::TUI::Fuzzy.match("glm", "glm-4.5") || raise "match failed").score
      scattered = (H2code::TUI::Fuzzy.match("glm", "x-g-l-m") || raise "match failed").score
      prefix.should be > scattered
    end

    it "scores consecutive matches higher than gapped ones" do
      tight = (H2code::TUI::Fuzzy.match("air", "glm-4.5-air") || raise "match failed").score
      gapped = (H2code::TUI::Fuzzy.match("air", "a___i___r") || raise "match failed").score
      tight.should be > gapped
    end

    it "rewards camelCase boundary matches" do
      camel = (H2code::TUI::Fuzzy.match("gf", "glmFour") || raise "match failed").score
      plain = (H2code::TUI::Fuzzy.match("gf", "glmfour") || raise "match failed").score
      camel.should be > plain
    end

    it "returns nil when not a subsequence" do
      H2code::TUI::Fuzzy.match("xyz", "glm-4.5").should be_nil
    end
  end

  describe ".filter (ranking)" do
    it "keeps only matching items, best score first, stable on ties" do
      items = ["glm-4.5", "glm-5.2", "gpt-4o", "glm-4.5-air"]
      ranked = H2code::TUI::Fuzzy.filter(items, "glm")
      # All three glm-* have 'glm' at the same leading positions, so their
      # scores tie and input order is preserved; gpt-4o is filtered out.
      ranked.map(&.[0]).should eq([0, 1, 3])
    end

    it "ranks a word-boundary match above a scattered one" do
      items = ["xglm", "glm-4.5"]
      ranked = H2code::TUI::Fuzzy.filter(items, "glm")
      ranked.map(&.[0]).should eq([1, 0])
    end

    it "returns empty for a query matching nothing" do
      items = ["glm-4.5", "glm-5.2"]
      H2code::TUI::Fuzzy.filter(items, "zzz").should be_empty
    end
  end
end

describe H2code::TUI::SelectList do
  it "filters items by a fuzzy query and reports them in score order" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["glm-4.5", "glm-5.2", "glm-4.5-air", "gpt-4o"])
    list.handle_input(H2code::TUI::KeyEvent.char('g'))
    list.handle_input(H2code::TUI::KeyEvent.char('l'))
    list.handle_input(H2code::TUI::KeyEvent.char('m'))

    list.query.should eq("glm")
    list.filtered_size.should eq(3)
    # No gpt-4o; equal scores keep input order.
    list.item_at(0).should eq("glm-4.5")
    list.item_at(1).should eq("glm-5.2")
    list.item_at(2).should eq("glm-4.5-air")
  end

  it "snaps the cursor to the top after each query edit" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["a", "b", "c"])
    list.selected = 2
    list.handle_input(H2code::TUI::KeyEvent.char('b'))
    list.query.should eq("b")
    list.selected.should eq(0)
    list.current.should eq("b")
  end

  it "backspace trims the query and restores matches" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["abc", "abd", "xyz"])
    list.handle_input(H2code::TUI::KeyEvent.char('a'))
    list.handle_input(H2code::TUI::KeyEvent.char('b'))
    list.filtered_size.should eq(2)
    list.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Backspace))
    list.query.should eq("a")
    list.filtered_size.should eq(2) # abc, abd still match "a"
  end

  it "clear_query restores the full list" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["a", "b", "c"])
    list.handle_input(H2code::TUI::KeyEvent.char('a'))
    list.filtered_size.should eq(1)
    list.clear_query.should be_true
    list.query.should eq("")
    list.filtered_size.should eq(3)
    list.clear_query.should be_false
  end

  it "ignores typed characters when not searchable" do
    list = H2code::TUI::SelectList.new
    list.show("Select theme", ["dark", "light"])
    consumed = list.handle_input(H2code::TUI::KeyEvent.char('d'))
    consumed.should be_false
    list.query.should eq("")
    list.filtered_size.should eq(2)
  end

  it "selected_original_index maps back to the unfiltered array" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["glm-4.5", "glm-5.2", "gpt-4o"])
    list.handle_input(H2code::TUI::KeyEvent.char('g'))
    list.handle_input(H2code::TUI::KeyEvent.char('p'))
    list.handle_input(H2code::TUI::KeyEvent.char('t'))
    list.current.should eq("gpt-4o")
    list.selected_original_index.should eq(2)
  end

  it "filters via content_filter, keeping original order (session picker)" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    # Item text is irrelevant here — the predicate decides, like the session
    # picker filtering by wire-log content.
    matching = Set{0, 2}
    list.content_filter = ->(_query : String, idx : Int32) { matching.includes?(idx) }
    list.show("Resume session", ["s1", "s2", "s3"])

    list.handle_input(H2code::TUI::KeyEvent.char('x'))
    list.filtered_size.should eq(2)
    list.item_at(0).should eq("s1")
    list.item_at(1).should eq("s3")
    list.selected_original_index.should eq(0)

    list.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Down))
    list.current.should eq("s3")
    list.selected_original_index.should eq(2)

    # Backspace to an empty query restores the full list in order.
    list.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Backspace))
    list.query.should eq("")
    list.filtered_size.should eq(3)
    list.item_at(2).should eq("s3")
  end

  it "content_filter receiving no matches yields an empty filtered list" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.content_filter = ->(_query : String, _idx : Int32) { false }
    list.show("Resume session", ["s1", "s2"])
    list.handle_input(H2code::TUI::KeyEvent.char('z'))
    list.filtered_size.should eq(0)
    list.current.should be_nil
  end

  it "builds the query from spaces too (substring search, not words)" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.content_filter = ->(query : String, _idx : Int32) { query == "log in" }
    list.show("Resume session", ["s1", "s2"])
    "log in".each_char { |c| list.handle_input(H2code::TUI::KeyEvent.char(c)) }
    list.query.should eq("log in")
    list.filtered_size.should eq(2)
    list.handle_input(H2code::TUI::KeyEvent.char('x'))
    list.query.should eq("log inx")
    list.filtered_size.should eq(0)
  end

  it "deferred_filter defers filtering to the owner via on_query_changed" do
    list = H2code::TUI::SelectList.new
    list.searchable = true
    list.deferred_filter = true
    queries = [] of String
    list.on_query_changed = ->(q : String) { queries << q; nil }
    list.content_filter = ->(query : String, _idx : Int32) { query == "ab" }
    list.show("Resume session", ["s1", "s2", "s3"])

    # Typing updates the query and notifies, but does NOT filter inline —
    # the list stays unfiltered until the owner applies the filter.
    list.handle_input(H2code::TUI::KeyEvent.char('a'))
    list.query.should eq("a")
    queries.should eq(["a"])
    list.filtered_size.should eq(3)

    # Backspace notifies too.
    list.handle_input(H2code::TUI::KeyEvent.char('b'))
    list.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Backspace))
    queries.should eq(["a", "ab", "a"])

    # The owner applies when its async search completes.
    list.handle_input(H2code::TUI::KeyEvent.char('b'))
    list.apply_filter
    list.filtered_size.should eq(3) # "ab" matches every index here
    list.query = "ab"
    list.flush_filter!.should be_nil # current: no-op, no exception

    # flush_filter! applies a stale query synchronously (Enter path).
    list.handle_input(H2code::TUI::KeyEvent.char('c'))
    list.query.should eq("abc")
    list.filtered_size.should eq(3) # still stale
    list.flush_filter!
    list.filtered_size.should eq(0) # nothing matches "abc"
  end
end
