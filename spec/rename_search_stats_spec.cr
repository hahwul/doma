require "./spec_helper"

describe "Database#rename_tag" do
  it "renames a tag in place when the destination is free" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal"])
      db.rename_tag("crystal", "cr").should eq(:renamed)
      db.directories.first.tags.should eq(["cr"])
      db.all_tags.map(&.name).should eq(["cr"])
    end
  end

  it "merges into an existing tag when one already holds the new name" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-a")
      tmp_b = File.tempname("doma-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["scratch"])
        db.add(tmp_b, ["tmp"])

        db.rename_tag("scratch", "tmp").should eq(:merged)
        db.all_tags.map(&.name).should eq(["tmp"])
        db.paths_for_tag("tmp").size.should eq(2)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "is a no-op when the names match" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal"])
      db.rename_tag("crystal", "crystal").should eq(:noop)
    end
  end

  it "raises NotFoundError when the source tag is missing" do
    with_temp_db do |db|
      expect_raises(Doma::NotFoundError) do
        db.rename_tag("does-not-exist", "anywhere")
      end
    end
  end

  it "validates the new tag name" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal"])
      expect_raises(Doma::ValidationError) do
        db.rename_tag("crystal", "bad name")
      end
    end
  end
end

describe "Database#search" do
  it "matches against path, basename, and tag name" do
    with_temp_db do |db|
      tmp = File.tempname("doma-search")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["crystal"])
        db.search("doma-search").map(&.path).should contain(Doma::Validator.canonicalize(tmp))
        db.search("crystal").map(&.path).should contain(Doma::Validator.canonicalize(tmp))
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "treats SQL LIKE meta-characters literally" do
    with_temp_db do |db|
      tmp = File.tempname("doma-search-pct")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["plain"])
        db.search("100%").should be_empty
        db.search("_anything_").should be_empty
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "Database#stats" do
  it "produces totals plus top tags and recent paths" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-st-a")
      tmp_b = File.tempname("doma-st-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["crystal", "cli"])
        db.add(tmp_b, ["crystal"])

        s = db.stats(top_n: 5, recent_n: 5)
        s.total_directories.should eq(2)
        s.total_tags.should eq(2)
        s.top_tags.first.name.should eq("crystal")
        s.top_tags.first.count.should eq(2)
        s.recent.size.should eq(2)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end
end
