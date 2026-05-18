require "./spec_helper"

describe Doma::Picker do
  describe ".filter" do
    items = [
      Doma::Picker::Item.new(value: "/Users/hahwul/Projects/doma", label: "/Users/hahwul/Projects/doma", hint: "#crystal #cli"),
      Doma::Picker::Item.new(value: "/Users/hahwul/Projects/hwaro", label: "/Users/hahwul/Projects/hwaro", hint: "#crystal #ssg"),
      Doma::Picker::Item.new(value: "/tmp/scratch", label: "/tmp/scratch", hint: nil),
    ]

    it "returns everything for an empty query" do
      Doma::Picker.filter(items, "").should eq(items)
    end

    it "matches against the label" do
      result = Doma::Picker.filter(items, "doma")
      result.size.should eq(1)
      result.first.value.should eq("/Users/hahwul/Projects/doma")
    end

    it "matches against the hint" do
      Doma::Picker.filter(items, "ssg").map(&.value).should eq(["/Users/hahwul/Projects/hwaro"])
    end

    it "is case-insensitive" do
      Doma::Picker.filter(items, "DOMA").size.should eq(1)
      Doma::Picker.filter(items, "Crystal").size.should eq(2)
    end

    it "returns an empty array for no matches" do
      Doma::Picker.filter(items, "totally-nonexistent").should be_empty
    end

    it "tolerates items without a hint" do
      Doma::Picker.filter(items, "scratch").map(&.value).should eq(["/tmp/scratch"])
    end
  end

  describe ".pick" do
    it "returns immediately for a single-item list" do
      items = [Doma::Picker::Item.new(value: "only", label: "only")]
      result = Doma::Picker.pick(items, "test")
      result.value.should eq("only")
      result.cancelled.should be_false
    end

    it "returns cancelled for an empty list" do
      result = Doma::Picker.pick([] of Doma::Picker::Item, "test")
      result.cancelled.should be_true
    end
  end

  describe "filter edge cases" do
    it "preserves the input order on empty query" do
      items = [
        Doma::Picker::Item.new(value: "1", label: "z"),
        Doma::Picker::Item.new(value: "2", label: "a"),
        Doma::Picker::Item.new(value: "3", label: "m"),
      ]
      Doma::Picker.filter(items, "").map(&.value).should eq(["1", "2", "3"])
    end

    it "tolerates items where hint is nil" do
      items = [
        Doma::Picker::Item.new(value: "x", label: "with-hint", hint: "extra"),
        Doma::Picker::Item.new(value: "y", label: "without-hint"),
      ]
      Doma::Picker.filter(items, "extra").map(&.value).should eq(["x"])
      Doma::Picker.filter(items, "without").map(&.value).should eq(["y"])
    end

    it "matches across both label and hint" do
      items = [
        Doma::Picker::Item.new(value: "a", label: "alpha", hint: "x"),
        Doma::Picker::Item.new(value: "b", label: "beta", hint: "alpha-tag"),
      ]
      # Both rows mention 'alpha' (label vs hint) — both should match.
      Doma::Picker.filter(items, "alpha").map(&.value).should eq(["a", "b"])
    end

    it "returns the same array (no panic) when query has no hits" do
      items = [Doma::Picker::Item.new(value: "1", label: "abc")]
      Doma::Picker.filter(items, "zzz").should be_empty
    end

    it "filter is stable (doesn't reorder matches)" do
      items = [
        Doma::Picker::Item.new(value: "1", label: "match-z"),
        Doma::Picker::Item.new(value: "2", label: "match-a"),
        Doma::Picker::Item.new(value: "3", label: "match-m"),
      ]
      Doma::Picker.filter(items, "match").map(&.value).should eq(["1", "2", "3"])
    end
  end

  describe ".sanitize" do
    it "passes plain ASCII and unicode through unchanged" do
      Doma::Picker.sanitize("/Users/me/projects/한국어").should eq("/Users/me/projects/한국어")
      Doma::Picker.sanitize("").should eq("")
    end

    it "replaces ESC and other control bytes with '?'" do
      # `\e[31mRED\e[0m` would otherwise render as a red label and could
      # be used to spoof which picker row is highlighted.
      Doma::Picker.sanitize("foo\e[31mbar").should eq("foo?[31mbar")
      Doma::Picker.sanitize("ab").should eq("a?b") # BEL
      Doma::Picker.sanitize("ab").should eq("a?b") # DEL
    end

    it "preserves tab — terminals render it as a column gap, not an injection" do
      Doma::Picker.sanitize("a\tb").should eq("a\tb")
    end
  end
end
