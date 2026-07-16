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

  it "preserves a TTL on the source row when merging into a permanent destination" do
    # Pre-fix: the merge `INSERT OR IGNORE` omitted `expires_at`, so a
    # source row carrying a TTL silently became permanent on the
    # destination tag. The user lost expiry information they had
    # explicitly set.
    with_temp_db do |db|
      tmp_a = File.tempname("doma-rn-ttl-a")
      tmp_b = File.tempname("doma-rn-ttl-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        future = Time.utc.to_unix + 7 * 86_400
        db.add(tmp_a, ["old"], expires_at: future)
        db.add(tmp_b, ["new"]) # permanent

        db.rename_tag("old", "new").should eq(:merged)

        a_id = db.directories.find! { |d| d.path == Doma::Validator.canonicalize(tmp_a) }.id
        ttls = db.tag_expirations(a_id)
        ttls["new"].should be_close(future, 5)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "keeps the longer-lived expiry when both tags collide on the same path" do
    # When a single path carries both tags with different TTLs, the
    # merged result should pick the more permissive lifetime so the
    # rename never *shortens* a TTL the user had set.
    with_temp_db do |db|
      tmp = File.tempname("doma-rn-ttl-collide")
      FileUtils.mkdir_p(tmp)
      begin
        far = Time.utc.to_unix + 14 * 86_400
        near = Time.utc.to_unix + 1 * 86_400
        db.add(tmp, ["a"], expires_at: far)
        db.add(tmp, ["b"], expires_at: near)

        db.rename_tag("a", "b").should eq(:merged)
        ttls = db.tag_expirations(db.directories.first.id)
        ttls["b"].should be_close(far, 5)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "keeps NULL (permanent) when one of the colliding rows has no TTL" do
    with_temp_db do |db|
      tmp = File.tempname("doma-rn-ttl-perm")
      FileUtils.mkdir_p(tmp)
      begin
        future = Time.utc.to_unix + 7 * 86_400
        db.add(tmp, ["a"], expires_at: future) # TTL'd
        db.add(tmp, ["b"])                     # permanent

        db.rename_tag("a", "b").should eq(:merged)
        db.tag_expirations(db.directories.first.id).has_key?("b").should be_false
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "Database#move_path merge" do
  it "carries a source TTL onto the destination instead of promoting it to permanent" do
    # Pre-fix: the merge INSERT omitted `expires_at`, so moving a TTL'd
    # tag onto an already-registered path silently made it permanent —
    # diverging from rename_tag, which carried the expiry through.
    with_temp_db do |db|
      tmp_a = File.tempname("doma-mv-ttl-a")
      tmp_b = File.tempname("doma-mv-ttl-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        future = Time.utc.to_unix + 7 * 86_400
        db.add(tmp_a, ["scratch"], expires_at: future)
        db.add(tmp_b, ["keep"]) # destination already registered → merge

        db.move_path(tmp_a, tmp_b).should eq(:merged)

        dest_id = db.directories.find! { |d| d.path == Doma::Validator.canonicalize(tmp_b) }.id
        db.tag_expirations(dest_id)["scratch"].should be_close(future, 5)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "keeps the more permissive lifetime when both sides carry the tag" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-mv-ttl-collide-a")
      tmp_b = File.tempname("doma-mv-ttl-collide-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        far = Time.utc.to_unix + 14 * 86_400
        near = Time.utc.to_unix + 1 * 86_400
        db.add(tmp_a, ["shared"], expires_at: near)
        db.add(tmp_b, ["shared"], expires_at: far)

        db.move_path(tmp_a, tmp_b).should eq(:merged)

        dest_id = db.directories.find! { |d| d.path == Doma::Validator.canonicalize(tmp_b) }.id
        db.tag_expirations(dest_id)["shared"].should be_close(far, 5)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "keeps NULL (permanent) when the destination tag has no TTL" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-mv-ttl-perm-a")
      tmp_b = File.tempname("doma-mv-ttl-perm-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        near = Time.utc.to_unix + 1 * 86_400
        db.add(tmp_a, ["shared"], expires_at: near) # TTL'd source
        db.add(tmp_b, ["shared"])                   # permanent destination

        db.move_path(tmp_a, tmp_b).should eq(:merged)

        dest_id = db.directories.find! { |d| d.path == Doma::Validator.canonicalize(tmp_b) }.id
        db.tag_expirations(dest_id).has_key?("shared").should be_false
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
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

  it "honors sort: Recent (and defaults to path order)" do
    # Regression guard: `search` used to hard-code ORDER BY path, so
    # `list <query> --by recent` silently ignored the sort flag.
    with_temp_db do |db|
      parent = File.tempname("doma-search-sort")
      first_by_path = File.join(parent, "aaa-proj")
      recently_used = File.join(parent, "zzz-proj")
      FileUtils.mkdir_p(first_by_path)
      FileUtils.mkdir_p(recently_used)
      begin
        db.add(first_by_path, [] of String)
        db.add(recently_used, [] of String)
        db.bump_used!(recently_used)

        db.search("proj").map(&.path).first
          .should eq(Doma::Validator.canonicalize(first_by_path))
        db.search("proj", sort: Doma::Database::SortBy::Recent).map(&.path).first
          .should eq(Doma::Validator.canonicalize(recently_used))
      ensure
        FileUtils.rm_rf(parent)
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

  it "matches data that literally contains '%' when the query has '%'" do
    # Negative-only coverage existed for the LIKE-escape; this is the
    # positive case — a basename truly containing the meta-char must
    # still be findable when the user types it.
    with_temp_db do |db|
      tmp_dir = File.tempname("doma-pct-parent")
      FileUtils.mkdir_p(tmp_dir)
      pct_dir = File.join(tmp_dir, "50%-done")
      FileUtils.mkdir_p(pct_dir)
      begin
        db.add(pct_dir, [] of String)
        hits = db.search("50%").map(&.path)
        hits.should contain(Doma::Validator.canonicalize(pct_dir))
      ensure
        FileUtils.rm_rf(tmp_dir)
      end
    end
  end

  it "matches a tag whose name literally contains '_' when the query has '_'" do
    with_temp_db do |db|
      tmp = File.tempname("doma-search-underscore")
      FileUtils.mkdir_p(tmp)
      begin
        # `_` is allowed by the tag pattern, so a literal underscore in
        # the user's tag must be findable via a `_`-bearing query.
        db.add(tmp, ["snake_case_tag"])
        hits = db.search("_case_").map(&.path)
        hits.should contain(Doma::Validator.canonicalize(tmp))
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "doesn't let '\\' in a query escape the next query character" do
    # The escape clause is `LIKE ? ESCAPE '\\'`, so a raw `\` in the
    # query string must itself be escaped before reaching SQLite —
    # otherwise `foo\bar` would silently behave as `foobar`.
    with_temp_db do |db|
      tmp_dir = File.tempname("doma-bs-parent")
      FileUtils.mkdir_p(tmp_dir)
      foo_bar = File.join(tmp_dir, "foobar")
      FileUtils.mkdir_p(foo_bar)
      begin
        db.add(foo_bar, [] of String)
        # `foo\bar` should NOT match `foobar` — backslash must be literal.
        db.search("foo\\bar").map(&.path).should be_empty
        # Sanity: the unescaped query still matches.
        db.search("foobar").map(&.path).should contain(Doma::Validator.canonicalize(foo_bar))
      ensure
        FileUtils.rm_rf(tmp_dir)
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
