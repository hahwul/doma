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

  describe "#bump_used!" do
    it "no-ops silently on a path that isn't registered" do
      with_temp_db do |db|
        # docstring promise: callers don't have to gate on existence.
        # If the row was pruned in a parallel session, the bump just
        # disappears.
        db.bump_used!("/definitely/not/registered") # must not raise
      end
    end

    it "updates last_used_at for a registered path" do
      with_temp_db do |db|
        tmp = File.tempname("doma-bump")
        FileUtils.mkdir_p(tmp)
        begin
          db.add(tmp, [] of String)
          before = db.db.scalar(
            "SELECT last_used_at FROM directories WHERE path = ?",
            Doma::Validator.canonicalize(tmp)
          ).as(Int64)
          db.bump_used!(tmp)
          after = db.db.scalar(
            "SELECT last_used_at FROM directories WHERE path = ?",
            Doma::Validator.canonicalize(tmp)
          ).as(Int64)
          after.should be > before
        ensure
          FileUtils.rm_rf(tmp)
        end
      end
    end
  end

  describe "#transaction" do
    it "rolls back on exception inside the block" do
      with_temp_db do |db|
        tmp = File.tempname("doma-tx-rb")
        FileUtils.mkdir_p(tmp)
        begin
          db.add(tmp, ["original"])
          before_count = db.directories.size

          # Block raises mid-stream — every write inside the
          # transaction must be rolled back, even the ones that
          # succeeded before the raise.
          expect_raises(Exception, /boom/) do
            db.transaction do |cnn|
              db.add_tx(cnn, "/some/other/path", ["another"], validate_path: false)
              raise "boom"
            end
          end

          db.directories.size.should eq(before_count)
        ensure
          FileUtils.rm_rf(tmp)
        end
      end
    end

    it "commits when the block returns normally" do
      with_temp_db do |db|
        tmp = File.tempname("doma-tx-ok")
        FileUtils.mkdir_p(tmp)
        begin
          db.transaction do |cnn|
            db.add_tx(cnn, tmp, ["committed"], validate_path: false)
          end
          db.paths_for_tag("committed").size.should eq(1)
        ensure
          FileUtils.rm_rf(tmp)
        end
      end
    end
  end
end
