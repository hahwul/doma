require "./spec_helper"

describe Doma::Database do
  it "adds a directory with tags" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal", "cli"])
      entries = db.directories
      entries.size.should eq(1)
      entries.first.path.should eq(Doma::Validator.canonicalize(Dir.current))
      entries.first.tags.should eq(["cli", "crystal"])
    end
  end

  it "filters directories by tag" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-a")
      tmp_b = File.tempname("doma-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["crystal"])
        db.add(tmp_b, ["python"])

        db.directories("crystal").map(&.path).should eq([Doma::Validator.canonicalize(tmp_a)])
        db.directories("python").map(&.path).should eq([Doma::Validator.canonicalize(tmp_b)])
        db.directories.size.should eq(2)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "removes specific tags without deleting the path" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal", "web"])
      db.remove_tags(Dir.current, ["web"])

      entries = db.directories
      entries.size.should eq(1)
      entries.first.tags.should eq(["crystal"])
    end
  end

  it "removes the path entirely" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal"])
      db.remove_path(Dir.current).should be_true
      db.directories.should be_empty
    end
  end

  it "returns tag summaries with counts" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-a")
      tmp_b = File.tempname("doma-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["crystal"])
        db.add(tmp_b, ["crystal", "cli"])

        summary = db.all_tags
        summary.map(&.name).should eq(["cli", "crystal"])
        summary.find! { |t| t.name == "crystal" }.count.should eq(2)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "garbage collects orphaned tags" do
    with_temp_db do |db|
      db.add(Dir.current, ["temp"])
      db.remove_tags(Dir.current, ["temp"])
      db.all_tags.should be_empty
    end
  end

  it "is idempotent on repeat add" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal"])
      db.add(Dir.current, ["crystal", "web"])

      entries = db.directories
      entries.size.should eq(1)
      entries.first.tags.should eq(["crystal", "web"])
    end
  end
end
