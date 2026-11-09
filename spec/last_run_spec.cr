require "./spec_helper"

describe Doma::LastRun do
  it "round-trips the failed paths and reads a missing or corrupt file as empty" do
    with_temp_db do |_db|
      Doma::LastRun.failed.should eq([] of String)
      Doma::LastRun.save(["/a", "/b"])
      Doma::LastRun.failed.should eq(["/a", "/b"])
      File.write(Doma::LastRun.path, "not json")
      Doma::LastRun.failed.should eq([] of String)
    end
  end
end
