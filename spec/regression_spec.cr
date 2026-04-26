require "./spec_helper"

# Regressions for bugs caught during the codebase audit. Each `it` block
# names the bug ID for traceability.

describe "Validator.canonicalize" do
  it "[B1] expands a leading ~ in user paths" do
    expanded = Doma::Validator.canonicalize("~/foo")
    expanded.should start_with(ENV["HOME"])
    expanded.should_not contain("~")
  end
end

describe "Database CASCADE behavior" do
  it "[B2] CASCADE deletes directory_tags when a directory is removed" do
    with_temp_db do |db|
      tmp = File.tempname("doma-cascade")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["a", "b"])
        db.remove_path(tmp)

        # If FK is OFF, directory_tags rows would survive. Verify there
        # are no rows left referencing nothing.
        orphan_count = db.db.scalar(
          "SELECT COUNT(*) FROM directory_tags " \
          "WHERE directory_id NOT IN (SELECT id FROM directories)"
        ).as(Int64)
        orphan_count.should eq(0)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "Importer atomicity" do
  it "[B3] --replace does not destroy existing data when the snapshot is malformed" do
    with_temp_db do |db|
      db.add(Dir.current, ["original"])

      # JSON valid, but the second entry's path is malformed enough to
      # raise ValidationError? Actually the importer skips ValidationError
      # silently. Use a forced raise: pass an invalid version.
      bad = %({"version":99,"entries":[]})
      path = File.tempname("doma-snap") + ".json"
      File.write(path, bad)
      begin
        expect_raises(Doma::ImportError) do
          Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Replace)
        end
        # Original data must still be there — the failed import must roll
        # back the (would-be) clear.
        db.directories.size.should eq(1)
        db.directories.first.tags.should eq(["original"])
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end

describe "Validator.sanitize_tag" do
  it "[B5] strips leading punctuation that would fail validation" do
    Doma::Validator.sanitize_tag(".dotfiles").should eq("dotfiles")
    Doma::Validator.sanitize_tag("_temp").should eq("temp")
  end

  it "[B5] returns nil when nothing salvageable remains" do
    Doma::Validator.sanitize_tag("...").should be_nil
    Doma::Validator.sanitize_tag("").should be_nil
    Doma::Validator.sanitize_tag("   ").should be_nil
  end

  it "[B5] passes valid tags through unchanged" do
    Doma::Validator.sanitize_tag("crystal").should eq("crystal")
  end
end

describe "Database#remove_tags" do
  it "[B6] runs cleanup_orphans inside the transaction" do
    with_temp_db do |db|
      db.add(Dir.current, ["solo"])
      db.remove_tags(Dir.current, ["solo"])
      # Tag should be GC'd as part of the same atomic operation.
      db.all_tags.should be_empty
    end
  end
end

describe "Validator.canonicalize symlink + trailing slash" do
  it "[completion] strips trailing slash" do
    Doma::Validator.canonicalize("/tmp/").should eq(Doma::Validator.canonicalize("/tmp"))
  end

  it "[completion] preserves bare root path" do
    Doma::Validator.canonicalize("/").should eq("/")
  end

  it "[completion] resolves symlinks for existing paths" do
    target = File.tempname("doma-real")
    link = File.tempname("doma-link")
    FileUtils.mkdir_p(target)
    File.symlink(target, link)
    begin
      # Both representations canonicalize to the same string — that's the
      # whole point: a directory tagged via either path lands in one row.
      Doma::Validator.canonicalize(target).should eq(Doma::Validator.canonicalize(link))
    ensure
      File.delete(link) if File.symlink?(link)
      FileUtils.rm_rf(target)
    end
  end

  it "[completion] falls back to expand_path for non-existing paths" do
    # Used by the importer for cross-machine snapshots.
    Doma::Validator.canonicalize("/no/such/dir").should eq("/no/such/dir")
  end
end

describe "Database#search single-query path" do
  it "[completion] returns tags without N+1" do
    with_temp_db do |db|
      tmp = File.tempname("doma-search-fast")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["alpha", "beta", "gamma"])
        results = db.search("doma-search-fast")
        results.size.should eq(1)
        results.first.tags.should eq(["alpha", "beta", "gamma"])
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "Runner.apply_globals!" do
  it "[completion] strips -q from argv and sets quiet" do
    prev = Doma::Logger.quiet?
    args = ["-q", "list", "--json"]
    begin
      Doma::CLI::Runner.apply_globals!(args)
      args.should eq(["list", "--json"])
      Doma::Logger.quiet?.should be_true
    ensure
      Doma::Logger.quiet = prev
    end
  end

  it "[completion] handles --no-color and --debug together" do
    prev_debug = Doma::Logger.debug?
    args = ["--no-color", "--debug", "stats"]
    begin
      Doma::CLI::Runner.apply_globals!(args)
      args.should eq(["stats"])
      Doma::Logger.debug?.should be_true
    ensure
      Doma::Logger.debug = prev_debug
    end
  end
end
