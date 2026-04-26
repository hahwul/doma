require "./spec_helper"

describe Doma::Selector do
  it "returns the only choice without consulting the strategy" do
    result = Doma::Selector.pick(["only"], mode: Doma::Settings::SelectorMode::First)
    result.value.should eq("only")
    result.cancelled.should be_false
  end

  it "first mode returns the first choice deterministically" do
    result = Doma::Selector.pick(["a", "b", "c"], mode: Doma::Settings::SelectorMode::First)
    result.value.should eq("a")
  end

  it "raises on empty input" do
    expect_raises(ArgumentError) do
      Doma::Selector.pick([] of String)
    end
  end
end
