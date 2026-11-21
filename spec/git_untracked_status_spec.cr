require "./spec_helper"

describe Doma::GitStatus do
  it "counts each untracked file even when git is configured to hide them" do
    pending! "git not on PATH" unless Doma::GitStatus.available?
    dir = File.tempname("doma-untracked")
    Dir.mkdir(dir)
    begin
      Process.run("git", ["-C", dir, "init", "-q"]).success?.should be_true
      Process.run("git", ["-C", dir, "config", "status.showUntrackedFiles", "no"]).success?.should be_true
      new_dir = File.join(dir, "new")
      Dir.mkdir(new_dir)
      File.write(File.join(new_dir, "one"), "")
      File.write(File.join(new_dir, "two"), "")

      status = Doma::GitStatus.probe(dir)
      status.untracked.should eq(2)
      status.dirty.should eq(2)
      status.clean?.should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
