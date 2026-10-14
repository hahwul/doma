require "./spec_helper"

private def entry(path : String)
  Doma::Entry.new(1_i64, "abc1234", path, File.basename(path), [] of String)
end

describe "TUI / picker regressions" do
  describe "Fuzzy with case-expanding characters" do
    it "keeps positions aligned when a char lowercases to two (İ)" do
      m = Doma::TUI::Fuzzy.score("d", "İİİİd").should_not be_nil
      m.positions.should eq([4])
    end

    it "matches past an İ without raising" do
      target = "/x/İstanbul/Kod"
      m = Doma::TUI::Fuzzy.score("kod", target).should_not be_nil
      m.positions.map { |i| target.char_at(i) }.join.should eq("Kod")
    end
  end

  describe "NFD paths" do
    nfd = "/Users/me/한글".unicode_normalize(:nfd)

    it "fuzzy-matches an NFC query in Query.filter" do
      scored = Doma::TUI::Query.filter([entry(nfd)], Doma::TUI::Query.parse("한글"))
      scored.size.should eq(1)
      drawn = nfd.unicode_normalize(:nfc)
      scored[0].positions.map { |i| drawn.char_at(i) }.join.should eq("한글")
    end

    it "substring-matches an NFC query in Picker.filter" do
      items = [Doma::Picker::Item.new(value: nfd, label: nfd)]
      Doma::Picker.filter(items, "한글").size.should eq(1)
    end
  end

  describe "Picker display width" do
    it "counts wide chars as two columns" do
      Doma::Picker.display_width("ab한글").should eq(6)
    end

    it "truncates by columns, not codepoints" do
      cut = Doma::Picker.truncate("한글한글한글", 7)
      cut.should eq("한글한…")
      Doma::Picker.display_width(cut).should be <= 7
    end

    it "leaves text that fits untouched" do
      Doma::Picker.truncate("한글", 4).should eq("한글")
    end
  end

  describe "time formatting at Int64 extremes" do
    it "absolute falls back instead of overflowing" do
      Doma::TimeFormatter.absolute(Int64::MAX).should eq("(invalid date)")
      Doma::TimeFormatter.absolute(Int64::MIN).should eq("(invalid date)")
    end

    it "relative_past handles Int64::MIN" do
      Doma::TimeFormatter.relative_past(Int64::MIN).should end_with("y ago")
    end

    it "humanize_remaining handles Int64::MIN and Int64::MAX" do
      Doma::Duration.humanize_remaining(Int64::MIN).should eq("expired")
      Doma::Duration.humanize_remaining(Int64::MAX).should end_with("w")
    end
  end
end
