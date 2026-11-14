require "./spec_helper"

private def entry(path : String, tags = [] of String)
  Doma::Entry.new(1_i64, "abc1234", path, File.basename(path), tags)
end

describe "Doma::TUI::Query.contains" do
  entries = [
    entry("/Users/hahwul/Projects/doma", %w[cli crystal]),
    entry("/Users/hahwul/Projects/hwaro", %w[crystal ssg]),
    entry("/tmp/scratch"),
  ]

  it "returns everything for an empty query" do
    Doma::TUI::Query.contains(entries, "").should eq(entries)
  end

  it "matches against the path" do
    Doma::TUI::Query.contains(entries, "doma").map(&.path).should eq(["/Users/hahwul/Projects/doma"])
  end

  it "matches against the #tag list" do
    Doma::TUI::Query.contains(entries, "ssg").map(&.path).should eq(["/Users/hahwul/Projects/hwaro"])
    Doma::TUI::Query.contains(entries, "#cli").map(&.path).should eq(["/Users/hahwul/Projects/doma"])
  end

  it "is case-insensitive" do
    Doma::TUI::Query.contains(entries, "DOMA").size.should eq(1)
    Doma::TUI::Query.contains(entries, "Crystal").size.should eq(2)
  end

  it "tolerates untagged entries and no hits" do
    Doma::TUI::Query.contains(entries, "scratch").map(&.path).should eq(["/tmp/scratch"])
    Doma::TUI::Query.contains(entries, "totally-nonexistent").should be_empty
  end

  it "keeps input order" do
    rows = [entry("/match-z"), entry("/match-a"), entry("/match-m")]
    Doma::TUI::Query.contains(rows, "match").map(&.path).should eq(["/match-z", "/match-a", "/match-m"])
  end
end

describe Doma::TUI::Text do
  describe ".sanitize" do
    it "passes plain ASCII and unicode through unchanged" do
      Doma::TUI::Text.sanitize("/Users/me/projects/한국어").should eq("/Users/me/projects/한국어")
      Doma::TUI::Text.sanitize("").should eq("")
    end

    it "replaces ESC and other control bytes with '?'" do
      # `\e[31mRED\e[0m` would otherwise render as a red label and could
      # be used to spoof which row is highlighted.
      Doma::TUI::Text.sanitize("foo\e[31mbar").should eq("foo?[31mbar")
      Doma::TUI::Text.sanitize("a\u0007b").should eq("a?b") # BEL
      Doma::TUI::Text.sanitize("a\u007fb").should eq("a?b") # DEL
    end

    it "preserves tab — terminals render it as a column gap, not an injection" do
      Doma::TUI::Text.sanitize("a\tb").should eq("a\tb")
    end
  end

  it "counts wide chars as two columns" do
    Doma::TUI::Text.display_width("ab한글").should eq(6)
  end

  it "tail_fit keeps the end that fits by columns" do
    Doma::TUI::Text.tail_fit("ab한글", 4).should eq("한글")
    Doma::TUI::Text.tail_fit("ab한글", 3).should eq("글")
  end
end
