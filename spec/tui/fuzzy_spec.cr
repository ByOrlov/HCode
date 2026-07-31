require "../spec_helper"

# Verifies the fuzzy matcher: subsequence requirement, scoring/ranking quality,
# match-position reconstruction (for highlighting), and `SelectList` filtering.
describe Hcode::TUI::Fuzzy do
  describe ".matches?" do
    it "matches a subsequence case-insensitively" do
      Hcode::TUI::Fuzzy.matches?("g45", "glm-4.5").should be_true
      Hcode::TUI::Fuzzy.matches?("G45", "glm-4.5").should be_true
    end

    it "rejects when chars are out of order or missing" do
      Hcode::TUI::Fuzzy.matches?("54", "glm-4.5").should be_false
      Hcode::TUI::Fuzzy.matches?("abc", "ab").should be_false
    end

    it "treats empty query as non-matching" do
      Hcode::TUI::Fuzzy.matches?("", "anything").should be_false
    end
  end

  describe ".match (score + positions)" do
    it "returns matched positions in ascending order" do
      res = Hcode::TUI::Fuzzy.match("g45", "glm-4.5")
      res.should_not be_nil
      res = res.not_nil!
      res.positions.should eq([0, 4, 6])
      res.score.should be > 0
    end

    it "scores a prefix/word-boundary match higher than a scattered one" do
      prefix = Hcode::TUI::Fuzzy.match("glm", "glm-4.5").not_nil!.score
      scattered = Hcode::TUI::Fuzzy.match("glm", "x-g-l-m").not_nil!.score
      prefix.should be > scattered
    end

    it "scores consecutive matches higher than gapped ones" do
      tight = Hcode::TUI::Fuzzy.match("air", "glm-4.5-air").not_nil!.score
      gapped = Hcode::TUI::Fuzzy.match("air", "a___i___r").not_nil!.score
      tight.should be > gapped
    end

    it "rewards camelCase boundary matches" do
      camel = Hcode::TUI::Fuzzy.match("gf", "glmFour").not_nil!.score
      plain = Hcode::TUI::Fuzzy.match("gf", "glmfour").not_nil!.score
      camel.should be > plain
    end

    it "returns nil when not a subsequence" do
      Hcode::TUI::Fuzzy.match("xyz", "glm-4.5").should be_nil
    end
  end

  describe ".filter (ranking)" do
    it "keeps only matching items, best score first, stable on ties" do
      items = ["glm-4.5", "glm-5.2", "gpt-4o", "glm-4.5-air"]
      ranked = Hcode::TUI::Fuzzy.filter(items, "glm")
      # All three glm-* have 'glm' at the same leading positions, so their
      # scores tie and input order is preserved; gpt-4o is filtered out.
      ranked.map(&.[0]).should eq([0, 1, 3])
    end

    it "ranks a word-boundary match above a scattered one" do
      items = ["xglm", "glm-4.5"]
      ranked = Hcode::TUI::Fuzzy.filter(items, "glm")
      ranked.map(&.[0]).should eq([1, 0])
    end

    it "returns empty for a query matching nothing" do
      items = ["glm-4.5", "glm-5.2"]
      Hcode::TUI::Fuzzy.filter(items, "zzz").should be_empty
    end
  end
end

describe Hcode::TUI::SelectList do
  it "filters items by a fuzzy query and reports them in score order" do
    list = Hcode::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["glm-4.5", "glm-5.2", "glm-4.5-air", "gpt-4o"])
    list.handle_input(Hcode::TUI::KeyEvent.char('g'))
    list.handle_input(Hcode::TUI::KeyEvent.char('l'))
    list.handle_input(Hcode::TUI::KeyEvent.char('m'))

    list.query.should eq("glm")
    list.filtered_size.should eq(3)
    # No gpt-4o; equal scores keep input order.
    list.item_at(0).should eq("glm-4.5")
    list.item_at(1).should eq("glm-5.2")
    list.item_at(2).should eq("glm-4.5-air")
  end

  it "snaps the cursor to the top after each query edit" do
    list = Hcode::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["a", "b", "c"])
    list.selected = 2
    list.handle_input(Hcode::TUI::KeyEvent.char('b'))
    list.query.should eq("b")
    list.selected.should eq(0)
    list.current.should eq("b")
  end

  it "backspace trims the query and restores matches" do
    list = Hcode::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["abc", "abd", "xyz"])
    list.handle_input(Hcode::TUI::KeyEvent.char('a'))
    list.handle_input(Hcode::TUI::KeyEvent.char('b'))
    list.filtered_size.should eq(2)
    list.handle_input(Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Backspace))
    list.query.should eq("a")
    list.filtered_size.should eq(2) # abc, abd still match "a"
  end

  it "clear_query restores the full list" do
    list = Hcode::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["a", "b", "c"])
    list.handle_input(Hcode::TUI::KeyEvent.char('a'))
    list.filtered_size.should eq(1)
    list.clear_query.should be_true
    list.query.should eq("")
    list.filtered_size.should eq(3)
    list.clear_query.should be_false
  end

  it "ignores typed characters when not searchable" do
    list = Hcode::TUI::SelectList.new
    list.show("Select theme", ["dark", "light"])
    consumed = list.handle_input(Hcode::TUI::KeyEvent.char('d'))
    consumed.should be_false
    list.query.should eq("")
    list.filtered_size.should eq(2)
  end

  it "selected_original_index maps back to the unfiltered array" do
    list = Hcode::TUI::SelectList.new
    list.searchable = true
    list.show("Select model", ["glm-4.5", "glm-5.2", "gpt-4o"])
    list.handle_input(Hcode::TUI::KeyEvent.char('g'))
    list.handle_input(Hcode::TUI::KeyEvent.char('p'))
    list.handle_input(Hcode::TUI::KeyEvent.char('t'))
    list.current.should eq("gpt-4o")
    list.selected_original_index.should eq(2)
  end
end
