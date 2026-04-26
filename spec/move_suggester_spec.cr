require "./spec_helper"

describe Doma::Suggester do
  it "suggests a near match within the distance budget" do
    Doma::Suggester.suggest("crystl", ["crystal", "python", "go"]).should eq("crystal")
  end

  it "returns nil when nothing is close enough" do
    Doma::Suggester.suggest("xyzqq", ["crystal", "python"]).should be_nil
  end

  it "returns nil for empty input" do
    Doma::Suggester.suggest("", ["crystal"]).should be_nil
  end

  it "scales tolerance with input size" do
    # Very short inputs only forgive 1 edit — 'cd' should NOT match 'add'.
    Doma::Suggester.suggest("cd", ["add", "list"]).should be_nil
  end

  it "renders a hint string ready for error.hint" do
    Doma::Suggester.hint_for("crystl", ["crystal"]).should eq("Did you mean 'crystal'?")
    Doma::Suggester.hint_for("xx", ["crystal"]).should be_nil
  end
end

describe "Database#move_path" do
  it "renames a directory entry while preserving tags" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-mv-a")
      tmp_b = File.tempname("doma-mv-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["crystal", "cli"])
        db.move_path(tmp_a, tmp_b).should eq(:moved)

        entries = db.directories
        entries.size.should eq(1)
        entries.first.path.should eq(Doma::Validator.canonicalize(tmp_b))
        entries.first.tags.should eq(["cli", "crystal"])
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "merges tags when the destination is already registered" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-mv-a2")
      tmp_b = File.tempname("doma-mv-b2")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["alpha"])
        db.add(tmp_b, ["beta"])
        db.move_path(tmp_a, tmp_b).should eq(:merged)

        db.directories.size.should eq(1)
        db.directories.first.tags.sort!.should eq(["alpha", "beta"])
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "raises NotFoundError with a hint when the source path is unknown" do
    with_temp_db do |db|
      tmp = File.tempname("doma-mv-known")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["x"])
        # Pass a clearly non-registered absolute path that exists, so path
        # validation succeeds but the lookup fails.
        ex = expect_raises(Doma::NotFoundError) do
          db.move_path("/etc", "/var/log")
        end
        # The error message should include the canonical input path.
        ex.message.should_not be_nil
        ex.message.try(&.includes?("/etc")).should be_true
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "is a no-op when old == new" do
    with_temp_db do |db|
      tmp = File.tempname("doma-mv-noop")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["x"])
        db.move_path(tmp, tmp).should eq(:noop)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end
