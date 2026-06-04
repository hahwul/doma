require "./spec_helper"

# The placeholder builder is tiny but it's the seam every batch statement
# (IN-lists and multi-row VALUES) threads through, so a drift here would
# corrupt SQL across sibling call sites. Lock the exact shapes in.
describe Doma::Sql do
  describe ".placeholders_for" do
    it "builds a flat `?,?,?` list by default" do
      Doma::Sql.placeholders_for(1).should eq("?")
      Doma::Sql.placeholders_for(3).should eq("?,?,?")
    end

    it "builds a parenthesized multi-row VALUES tail with an explicit group" do
      Doma::Sql.placeholders_for(2, "(?, ?)").should eq("(?, ?),(?, ?)")
    end

    it "returns an empty string for a zero count" do
      Doma::Sql.placeholders_for(0).should eq("")
    end

    it "emits exactly n groups" do
      Doma::Sql.placeholders_for(4).split(",").size.should eq(4)
      Doma::Sql.placeholders_for(4, "(?, ?)").scan(/\(\?, \?\)/).size.should eq(4)
    end
  end
end
