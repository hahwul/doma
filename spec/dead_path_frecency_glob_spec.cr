require "./spec_helper"

# Specs for the four "polish" features added in one batch:
#   - dead-path detection / pruning
#   - frecency tracking + recency-ordered queries
#   - tag-glob matching
#   - migrations idempotency

describe "Dead path detection (#2)" do
  it "lists entries whose path is gone via dead_paths" do
    with_temp_db do |db|
      live = File.tempname("doma-alive")
      gone = File.tempname("doma-gone")
      FileUtils.mkdir_p(live)
      FileUtils.mkdir_p(gone)
      # Capture the canonical form *before* deletion — once the dir is
      # gone, `realpath` can't resolve the symlink leg, so canonicalize
      # falls back to plain expand_path and would mismatch the DB value.
      gone_canonical = Doma::Validator.canonicalize(gone)
      db.add(live, ["live"])
      db.add(gone, ["gone"])
      FileUtils.rm_rf(gone)
      begin
        dead = db.dead_paths
        dead.size.should eq(1)
        dead.first.path.should eq(gone_canonical)
      ensure
        FileUtils.rm_rf(live)
      end
    end
  end

  it "prune_dead! removes only missing rows and reports the count" do
    with_temp_db do |db|
      live = File.tempname("doma-alive2")
      gone = File.tempname("doma-gone2")
      FileUtils.mkdir_p(live)
      FileUtils.mkdir_p(gone)
      db.add(live, ["a"])
      db.add(gone, ["b"])
      FileUtils.rm_rf(gone)
      begin
        db.prune_dead!.should eq(1)
        db.directories.size.should eq(1)
        db.directories.first.path.should eq(Doma::Validator.canonicalize(live))
        # Orphan tag (`b` had only one host) should also be GC'd.
        db.all_tags.map(&.name).should eq(["a"])
      ensure
        FileUtils.rm_rf(live)
      end
    end
  end

  it "remove_ids! deletes exactly the given rows and GCs orphan tags" do
    with_temp_db do |db|
      a = File.tempname("doma-rid-a")
      b = File.tempname("doma-rid-b")
      [a, b].each { |d| FileUtils.mkdir_p(d) }
      begin
        # Both paths still exist on disk: unlike prune_dead!, remove_ids!
        # trusts the caller's set rather than re-stating the filesystem.
        # This is what lets `prune --gone` delete exactly what it
        # snapshotted to the trash, with no second stat pass to diverge.
        db.add(a, ["keep"])
        db.add(b, ["drop"])
        target = db.directories.find! { |e| e.path == Doma::Validator.canonicalize(b) }

        db.remove_ids!([target.id]).should eq(1)

        db.directories.map(&.path).should eq([Doma::Validator.canonicalize(a)])
        # `drop` had only the removed host, so it's garbage-collected.
        db.all_tags.map(&.name).should eq(["keep"])
      ensure
        [a, b].each { |d| FileUtils.rm_rf(d) }
      end
    end
  end

  it "remove_ids! is a no-op (returns 0) for an empty id list" do
    with_temp_db do |db|
      tmp = File.tempname("doma-rid-empty")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["x"])
        db.remove_ids!([] of Int64).should eq(0)
        db.directories.size.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "Frecency (#3)" do
  it "schema migration adds last_used_at" do
    with_temp_db do |db|
      cols = db.db.query_all(
        "PRAGMA table_info(directories)",
        as: {Int32, String, String, Int32, String?, Int32}
      ).map { |row| row[1] }
      cols.should contain("last_used_at")
    end
  end

  it "PRAGMA user_version equals CURRENT_VERSION after open" do
    with_temp_db do |db|
      db.db.scalar("PRAGMA user_version").as(Int64)
        .should eq(Doma::Migrations::CURRENT_VERSION.to_i64)
    end
  end

  it "bump_used! updates last_used_at and orders results by recency" do
    with_temp_db do |db|
      a = File.tempname("doma-fa")
      b = File.tempname("doma-fb")
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)
      begin
        db.add(a, ["shared"])
        db.add(b, ["shared"])

        # Bump `b` so it should sort first.
        db.bump_used!(b)
        ordered = db.paths_for_tag("shared")
        ordered.first.should eq(Doma::Validator.canonicalize(b))
      ensure
        FileUtils.rm_rf(a)
        FileUtils.rm_rf(b)
      end
    end
  end

  it "stats.most_used skips entries that were never used" do
    with_temp_db do |db|
      tmp = File.tempname("doma-fnone")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["fresh"])
        db.stats.most_used.should be_empty
        db.bump_used!(tmp)
        db.stats.most_used.size.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "directories(sort: Recent) orders by last_used_at" do
    with_temp_db do |db|
      a = File.tempname("doma-sa")
      b = File.tempname("doma-sb")
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)
      begin
        db.add(a, [] of String)
        db.add(b, [] of String)
        db.bump_used!(a)
        first = db.directories(sort: Doma::Database::SortBy::Recent).first
        first.path.should eq(Doma::Validator.canonicalize(a))
      ensure
        FileUtils.rm_rf(a)
        FileUtils.rm_rf(b)
      end
    end
  end
end

describe "Tag glob (#4)" do
  it "matches tags via SQLite GLOB when the input contains *" do
    with_temp_db do |db|
      a = File.tempname("doma-ga")
      b = File.tempname("doma-gb")
      c = File.tempname("doma-gc")
      [a, b, c].each { |d| FileUtils.mkdir_p(d) }
      begin
        db.add(a, ["work-foo"])
        db.add(b, ["work-bar"])
        db.add(c, ["home"])

        matched = db.paths_for_tag("work-*").map { |p| File.basename(p) }
        matched.size.should eq(2)
        matched.should contain(File.basename(Doma::Validator.canonicalize(a)))
        matched.should contain(File.basename(Doma::Validator.canonicalize(b)))
      ensure
        [a, b, c].each { |d| FileUtils.rm_rf(d) }
      end
    end
  end

  it "supports ? as single-character wildcard" do
    with_temp_db do |db|
      tmp = File.tempname("doma-glob-q")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["v1"])
        db.paths_for_tag("v?").size.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "exact match still works for non-glob inputs" do
    with_temp_db do |db|
      tmp = File.tempname("doma-glob-exact")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["work"])
        db.paths_for_tag("work").size.should eq(1)
        # 'work' shouldn't match 'workshop' or 'rework' under exact mode.
        db.paths_for_tag("wor").should be_empty
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  # `paths_for_tag` is the cd-side helper; `directories(tag)` is what
  # `list -t` calls. Both share `tag_match_clause`, but only the former
  # had glob coverage — these specs lock the list-side branch in.
  it "directories(tag) honors `*` glob and returns hydrated entries" do
    with_temp_db do |db|
      a = File.tempname("doma-dirs-glob-a")
      b = File.tempname("doma-dirs-glob-b")
      c = File.tempname("doma-dirs-glob-c")
      [a, b, c].each { |d| FileUtils.mkdir_p(d) }
      begin
        db.add(a, ["work-foo"])
        db.add(b, ["work-bar"])
        db.add(c, ["home"])

        entries = db.directories("work-*")
        entries.map(&.tags.first).sort!.should eq(["work-bar", "work-foo"])
        # Tags must be hydrated, not blank — same shape as exact-match.
        entries.each(&.tags.should_not(be_empty))
      ensure
        [a, b, c].each { |d| FileUtils.rm_rf(d) }
      end
    end
  end

  it "directories(tag) honors `?` glob" do
    with_temp_db do |db|
      a = File.tempname("doma-dirs-q-a")
      b = File.tempname("doma-dirs-q-b")
      [a, b].each { |d| FileUtils.mkdir_p(d) }
      begin
        db.add(a, ["v1"])
        db.add(b, ["v12"])
        db.directories("v?").size.should eq(1)
      ensure
        [a, b].each { |d| FileUtils.rm_rf(d) }
      end
    end
  end

  it "directories(tag) glob respects expired-row filtering" do
    # Pre-fix risk: a glob match could surface paths whose only matching
    # tag is expired, undermining the same-row-hiding contract that
    # exact-match queries already honor.
    with_temp_db do |db|
      a = File.tempname("doma-dirs-glob-exp-a")
      b = File.tempname("doma-dirs-glob-exp-b")
      [a, b].each { |d| FileUtils.mkdir_p(d) }
      begin
        db.add(a, ["work-foo"], expires_at: Time.utc.to_unix - 60) # already expired
        db.add(b, ["work-bar"])

        active = db.directories("work-*")
        active.size.should eq(1)
        active.first.tags.should eq(["work-bar"])

        # --include-expired surfaces the lapsed row again.
        all = db.directories("work-*", include_expired: true)
        all.size.should eq(2)
      ensure
        [a, b].each { |d| FileUtils.rm_rf(d) }
      end
    end
  end
end
