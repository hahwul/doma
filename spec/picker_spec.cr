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
end
