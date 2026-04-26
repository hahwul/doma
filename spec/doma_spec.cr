require "./spec_helper"

describe Doma do
  it "exposes a version" do
    Doma::VERSION.should_not be_empty
  end
end
