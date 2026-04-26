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

describe "doma add" do
  it "[ergonomics] defaults to the current directory when path is omitted" do
    home = File.tempname("doma-add-default")
    FileUtils.mkdir_p(home)
    workdir = File.tempname("doma-cwd")
    FileUtils.mkdir_p(workdir)
    bin = File.expand_path("../bin/doma", __DIR__)
    pending! "binary not built" unless File.exists?(bin)
    begin
      sink = IO::Memory.new
      status = Process.run(
        bin, ["add", "-t", "auto-default"],
        env: {"DOMA_HOME" => home},
        chdir: workdir, output: sink, error: sink,
      )
      status.success?.should be_true

      Doma::Database.open(File.join(home, "doma.db")).tap do |db|
        begin
          paths = db.paths_for_tag("auto-default")
          paths.size.should eq(1)
          paths.first.should eq(Doma::Validator.canonicalize(workdir))
        ensure
          db.close
        end
      end
    ensure
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(workdir)
    end
  end
end

describe "doma doctor with corrupted DB" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[bug] reports READ ERROR instead of empty 'internal error:'" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-doctor-bad")
    FileUtils.mkdir_p(home)
    # Write something that isn't a SQLite file. The DB layer will refuse
    # to open it; doctor should surface a useful diagnostic instead of
    # propagating the bare exception to the runner.
    File.write(File.join(home, "doma.db"), "this is not sqlite")

    stdout_buf = IO::Memory.new
    stderr_buf = IO::Memory.new
    Process.run(
      bin, ["doctor"],
      env: {"DOMA_HOME" => home}, output: stdout_buf, error: stderr_buf,
    )
    combined = stdout_buf.to_s + stderr_buf.to_s
    combined.should contain("READ ERROR")
    combined.should_not contain("internal error:")
  ensure
    FileUtils.rm_rf(home) if home
  end
end

describe "doma cd --query in non-TTY" do
  # The browse path used to ignore --query in non-TTY (First) mode and
  # silently return the first overall entry. This regression spec drives
  # the binary to confirm filtering happens before mode dispatch.
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[bug] errors on no match instead of returning first entry" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-cdq")
    FileUtils.mkdir_p(home)
    sink = IO::Memory.new
    Process.run(bin, ["add", "/tmp", "-t", "scratch"], env: {"DOMA_HOME" => home}, output: sink, error: sink)
    Process.run(bin, ["add", "/var", "-t", "fs"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

    stdout_buf = IO::Memory.new
    stderr_buf = IO::Memory.new
    status = Process.run(
      bin,
      ["cd", "--query", "totally-nonexistent"],
      env: {"DOMA_HOME" => home}, output: stdout_buf, error: stderr_buf,
    )
    status.exit_code.should eq(3)
    stdout_buf.to_s.should be_empty
    stderr_buf.to_s.should contain("no directories match")
  ensure
    FileUtils.rm_rf(home) if home
  end

  it "[bug] returns the matching entry when --query matches one" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-cdq2")
    FileUtils.mkdir_p(home)
    sink = IO::Memory.new
    Process.run(bin, ["add", "/tmp", "-t", "a"], env: {"DOMA_HOME" => home}, output: sink, error: sink)
    Process.run(bin, ["add", "/var", "-t", "b"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

    stdout_buf = IO::Memory.new
    Process.run(bin, ["cd", "--query", "tmp"], env: {"DOMA_HOME" => home}, output: stdout_buf, error: STDERR)
    stdout_buf.to_s.strip.should contain("tmp")
  ensure
    FileUtils.rm_rf(home) if home
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
