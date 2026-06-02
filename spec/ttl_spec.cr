require "./spec_helper"

describe Doma::Duration do
  it "parses single-unit durations" do
    Doma::Duration.parse_seconds!("30s").should eq(30_i64)
    Doma::Duration.parse_seconds!("5m").should eq(300_i64)
    Doma::Duration.parse_seconds!("1h").should eq(3600_i64)
    Doma::Duration.parse_seconds!("7d").should eq(7 * 86_400_i64)
    Doma::Duration.parse_seconds!("2w").should eq(2 * 7 * 86_400_i64)
  end

  it "is case-insensitive on the unit" do
    Doma::Duration.parse_seconds!("1H").should eq(3600_i64)
  end

  it "rejects malformed input" do
    expect_raises(Doma::ValidationError, /invalid duration/) { Doma::Duration.parse_seconds!("forever") }
    expect_raises(Doma::ValidationError, /invalid duration/) { Doma::Duration.parse_seconds!("1d2h") }
    expect_raises(Doma::ValidationError, /invalid duration/) { Doma::Duration.parse_seconds!("5") }
  end

  it "rejects zero / negative" do
    expect_raises(Doma::ValidationError, /positive/) { Doma::Duration.parse_seconds!("0d") }
  end

  it "tolerates surrounding whitespace" do
    Doma::Duration.parse_seconds!("  7d  ").should eq(7 * 86_400_i64)
  end

  it "rejects fractional values" do
    expect_raises(Doma::ValidationError, /invalid duration/) do
      Doma::Duration.parse_seconds!("1.5d")
    end
  end

  it "rejects negative sign" do
    expect_raises(Doma::ValidationError, /invalid duration/) do
      Doma::Duration.parse_seconds!("-5m")
    end
  end

  it "rejects values above the ~100y cap with a clean ValidationError" do
    # Pre-fix this surfaced as a generic 'internal error: Invalid time'
    # because the multiplied product blew past Crystal's Time range.
    expect_raises(Doma::ValidationError, /too large/) do
      Doma::Duration.parse_seconds!("9999999999999w")
    end
  end

  it "rejects digit strings that don't fit Int64 with a ValidationError" do
    # 20+ digits overflows the int parse before we even multiply.
    expect_raises(Doma::ValidationError, /too large/) do
      Doma::Duration.parse_seconds!("99999999999999999999s")
    end
  end

  it ".expires_at_for returns now + duration in epoch seconds" do
    before = Time.utc.to_unix
    epoch = Doma::Duration.expires_at_for("60s")
    after = Time.utc.to_unix
    (epoch - before).should be >= 60
    (epoch - after).should be <= 60
  end

  it ".default_tmp_expires_at is roughly 7 days out" do
    epoch = Doma::Duration.default_tmp_expires_at
    expected = Time.utc.to_unix + Doma::Duration::DEFAULT_TMP_SECONDS
    (epoch - expected).abs.should be <= 2 # allow tiny clock drift
  end
end

describe "TTL: Database.add with expires_at" do
  it "stores expires_at on the directory_tags row" do
    with_temp_db do |db|
      tmp = File.tempname("doma-ttl")
      FileUtils.mkdir_p(tmp)
      future = Time.utc.to_unix + 60
      begin
        db.add(tmp, ["temp"], expires_at: future)
        # Active immediately — query reflects it.
        db.paths_for_tag("temp").size.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "filters out expired rows from paths_for_tag" do
    with_temp_db do |db|
      tmp = File.tempname("doma-ttl-past")
      FileUtils.mkdir_p(tmp)
      past = Time.utc.to_unix - 60
      begin
        db.add(tmp, ["stale"], expires_at: past)
        db.paths_for_tag("stale").should be_empty
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "filters expired tag matches in directories(tag)" do
    with_temp_db do |db|
      tmp = File.tempname("doma-ttl-dir")
      FileUtils.mkdir_p(tmp)
      past = Time.utc.to_unix - 60
      begin
        db.add(tmp, ["gone"], expires_at: past)
        db.directories("gone").should be_empty
        # include_expired bypasses the filter for audit / cleanup.
        db.directories("gone", include_expired: true).size.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "re-tagging refreshes expires_at" do
    with_temp_db do |db|
      tmp = File.tempname("doma-ttl-refresh")
      FileUtils.mkdir_p(tmp)
      past = Time.utc.to_unix - 60
      begin
        db.add(tmp, ["bookmark"], expires_at: past)
        db.paths_for_tag("bookmark").should be_empty

        # Re-tag with future expiration → should become active again.
        future = Time.utc.to_unix + 3600
        db.add(tmp, ["bookmark"], expires_at: future)
        db.paths_for_tag("bookmark").size.should eq(1)

        # Re-tag without --ttl → reverts to permanent (NULL expiry).
        db.add(tmp, ["bookmark"])
        db.paths_for_tag("bookmark").size.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "active tags coexist with expired tags on the same path" do
    with_temp_db do |db|
      tmp = File.tempname("doma-ttl-mixed")
      FileUtils.mkdir_p(tmp)
      past = Time.utc.to_unix - 60
      begin
        db.add(tmp, ["permanent"])
        db.add(tmp, ["temp"], expires_at: past)

        entries = db.directories
        entries.size.should eq(1)
        entries.first.tags.should eq(["permanent"])

        # include_expired surfaces both.
        db.directories(include_expired: true).first.tags.sort!.should eq(["permanent", "temp"])

        # `tags`/`stats` must agree with `list`: the expired `temp` tag is
        # hidden and never inflates a count. (Regression: it used to leak
        # into all_tags / stats while `list -t temp` returned nothing.)
        db.all_tags.map(&.name).should eq(["permanent"])
        db.all_tags.find!(&.name.== "permanent").count.should eq(1)

        s = db.stats
        s.total_tags.should eq(1)
        s.top_tags.map(&.name).should eq(["permanent"])
        s.top_tags.first.count.should eq(1)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "excludes expired associations from a tag's count without dropping the tag" do
    with_temp_db do |db|
      live = File.tempname("doma-ttl-live")
      gone = File.tempname("doma-ttl-gone")
      FileUtils.mkdir_p(live)
      FileUtils.mkdir_p(gone)
      past = Time.utc.to_unix - 60
      begin
        # Same tag on two dirs: one association active, one expired. The
        # count should be 1 (active only), and the tag must stay listed.
        db.add(live, ["shared"])
        db.add(gone, ["shared"], expires_at: past)

        summary = db.all_tags.find!(&.name.== "shared")
        summary.count.should eq(1)

        s = db.stats
        s.total_tags.should eq(1)
        s.top_tags.find!(&.name.== "shared").count.should eq(1)
      ensure
        FileUtils.rm_rf(live)
        FileUtils.rm_rf(gone)
      end
    end
  end
end

describe "Database#prune_expired!" do
  it "deletes expired directory_tags rows and reports the count" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-prune-a")
      tmp_b = File.tempname("doma-prune-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      past = Time.utc.to_unix - 60
      begin
        db.add(tmp_a, ["keep"])
        db.add(tmp_a, ["drop"], expires_at: past)
        db.add(tmp_b, ["drop2"], expires_at: past)

        db.prune_expired!.size.should eq(2)

        # Permanent tag still present.
        db.directories(include_expired: true).find!(&.path.==(Doma::Validator.canonicalize(tmp_a))).tags
          .should eq(["keep"])
        # Orphan `drop`/`drop2` tags collected.
        db.all_tags.map(&.name).should eq(["keep"])
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end
end

describe "doma mark CLI alias" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[ergonomics] tags cwd with --tmp default (single tag)" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-mark-1")
    workdir = File.tempname("doma-mark-cwd1")
    FileUtils.mkdir_p(home)
    FileUtils.mkdir_p(workdir)
    begin
      sink = IO::Memory.new
      status = Process.run(
        bin, ["mark", "reading"],
        env: {"DOMA_HOME" => home}, chdir: workdir, output: sink, error: sink,
      )
      status.success?.should be_true

      Doma::Database.open(File.join(home, "doma.db")).tap do |db|
        begin
          db.paths_for_tag("reading").size.should eq(1)
          # The tag must have a TTL — that's the whole point of mark.
          # Re-query the row directly to confirm expires_at != NULL.
          row = db.db.query_one?(
            "SELECT dt.expires_at FROM directory_tags dt " \
            "INNER JOIN tags t ON t.id = dt.tag_id " \
            "WHERE t.name = ?",
            "reading", as: Int64?
          )
          row.should_not be_nil
        ensure
          db.close
        end
      end
    ensure
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(workdir)
    end
  end

  it "[ergonomics] accepts multiple tags as positional args" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-mark-2")
    workdir = File.tempname("doma-mark-cwd2")
    FileUtils.mkdir_p(home)
    FileUtils.mkdir_p(workdir)
    begin
      sink = IO::Memory.new
      Process.run(
        bin, ["mark", "spike", "skim", "review"],
        env: {"DOMA_HOME" => home}, chdir: workdir, output: sink, error: sink,
      )

      Doma::Database.open(File.join(home, "doma.db")).tap do |db|
        begin
          db.paths_for_tag("spike").size.should eq(1)
          db.paths_for_tag("skim").size.should eq(1)
          db.paths_for_tag("review").size.should eq(1)
        ensure
          db.close
        end
      end
    ensure
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(workdir)
    end
  end

  it "[ergonomics] rejects empty tag list" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-mark-3")
    FileUtils.mkdir_p(home)
    begin
      sink = IO::Memory.new
      err = IO::Memory.new
      status = Process.run(
        bin, ["mark"],
        env: {"DOMA_HOME" => home}, output: sink, error: err,
      )
      status.exit_code.should eq(2)
      err.to_s.should contain("at least one tag")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

describe "Database#directories_by_short_id_prefix" do
  it "returns all matches for a prefix" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-pfx-a")
      tmp_b = File.tempname("doma-pfx-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, [] of String)
        db.add(tmp_b, [] of String)
        # The empty prefix matches every directory — useful as a
        # sentinel for "give me everything via this resolver".
        all = db.directories_by_short_id_prefix("")
        all.size.should eq(2)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "resolves a unique 2-char prefix" do
    with_temp_db do |db|
      tmp = File.tempname("doma-pfx-uniq")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, [] of String)
        full = db.directories.first.short_id
        hits = db.directories_by_short_id_prefix(full[0, 2])
        hits.size.should eq(1)
        hits.first.short_id.should eq(full)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "is empty for non-matching prefixes" do
    with_temp_db do |db|
      tmp = File.tempname("doma-pfx-miss")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, [] of String)
        # `xyz` is hex-illegal, but the DB query doesn't care — it just
        # returns nothing. The cd command's hex precheck is what guards
        # against weird tag-typos pulling in unrelated short_ids.
        db.directories_by_short_id_prefix("zzzzzzz").should be_empty
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "Schema v3: short_id" do
  it "every directory has a unique 7-char short_id" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-sid-a")
      tmp_b = File.tempname("doma-sid-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, [] of String)
        db.add(tmp_b, [] of String)
        ids = db.directories.map(&.short_id)
        ids.size.should eq(2)
        ids.uniq!.size.should eq(2)
        ids.each(&.size.should(eq(7)))
        ids.each(&.matches?(/\A[0-9a-f]{7}\z/).should(be_true))
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "preserves short_id across re-adds (stable handle)" do
    with_temp_db do |db|
      tmp = File.tempname("doma-sid-stable")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["one"])
        first = db.directories.first.short_id

        db.add(tmp, ["two"])
        second = db.directories.first.short_id

        first.should eq(second)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end
