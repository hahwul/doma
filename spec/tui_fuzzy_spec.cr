require "./spec_helper"

# Pure-logic coverage for the fuzzy scorer. No terminal involved — mirrors the
# tty-free style of `tag_glob_spec` / `picker_spec.filter`.

# Unwraps a successful match, failing the example (without `not_nil!`, which the
# project lints against) if the query didn't match.
private def score!(query : String, target : String, basename_bonus : Bool = true) : Doma::TUI::Fuzzy::Match
  m = Doma::TUI::Fuzzy.score(query, target, basename_bonus: basename_bonus)
  m.should_not be_nil
  m.as(Doma::TUI::Fuzzy::Match)
end

describe Doma::TUI::Fuzzy do
  describe ".score" do
    it "returns a zero-score match for an empty query" do
      m = score!("", "/Users/h/Projects/doma")
      m.score.should eq(0)
      m.positions.should be_empty
    end

    it "returns nil when the query is not a subsequence" do
      Doma::TUI::Fuzzy.score("xyz", "/Users/h/doma").should be_nil
    end

    it "matches a subsequence and reports the matched indices" do
      # 'd' at 0, 'm' at 2
      score!("dm", "doma").positions.should eq([0, 2])
    end

    it "is case-insensitive" do
      Doma::TUI::Fuzzy.score("DOMA", "doma").should_not be_nil
      Doma::TUI::Fuzzy.score("doma", "DOMA").should_not be_nil
    end

    it "scores a contiguous run higher than a scattered one" do
      score!("ab", "ab").score.should be > score!("ab", "axxxb").score
    end

    it "rewards a match at a word boundary over one mid-word" do
      boundary = score!("d", "/x/doma", basename_bonus: false).score
      midword = score!("d", "/x/adoma", basename_bonus: false).score
      boundary.should be > midword
    end

    it "ranks a basename match above a mid-path match" do
      score!("doma", "/p/doma").score.should be > score!("doma", "/p/domain/x").score
    end

    it "disables the basename bonus when asked (path: operator)" do
      with_bonus = score!("doma", "/p/doma", basename_bonus: true).score
      without = score!("doma", "/p/doma", basename_bonus: false).score
      with_bonus.should be > without
    end

    it "indexes by codepoint, not byte, for multibyte paths" do
      # '한' is one codepoint but several UTF-8 bytes; the matched position
      # must be the codepoint index so highlight lines up with set_cell.
      score!("한", "/x/한국").positions.should eq([3])
    end
  end
end
