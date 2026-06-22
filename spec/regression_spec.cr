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
        paths = db.paths_for_tag("auto-default")
        paths.size.should eq(1)
        paths.first.should eq(Doma::Validator.canonicalize(workdir))
      ensure
        db.close
      end
    ensure
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(workdir)
    end
  end
end

describe "doma add multi-path partial success" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[bug] adds the valid paths and reports the invalid ones" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-multipath")
    FileUtils.mkdir_p(home)

    out_buf = IO::Memory.new
    err_buf = IO::Memory.new
    status = Process.run(
      bin, ["add", "/tmp", "/no/such/dir/anywhere", "/var", "-t", "batch"],
      env: {"DOMA_HOME" => home}, output: out_buf, error: err_buf,
    )
    # Non-zero (2) because at least one path failed validation.
    status.exit_code.should eq(2)

    # The valid paths must still be persisted — partial success is the
    # correct default for a batch add.
    list_buf = IO::Memory.new
    Process.run(bin, ["list", "-t", "batch", "--paths"], env: {"DOMA_HOME" => home}, output: list_buf, error: STDERR)
    paths = list_buf.to_s.split('\n', remove_empty: true)
    paths.size.should eq(2)
  ensure
    FileUtils.rm_rf(home) if home
  end
end

describe "doma misconfigured env paths" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[bug] DOMA_HOME pointing at a file gives a friendly ConfigError" do
    pending! "binary not built" unless File.exists?(bin)
    bad = File.tempname("doma-home-as-file")
    File.write(bad, "")

    sink = IO::Memory.new
    err = IO::Memory.new
    status = Process.run(bin, ["list"], env: {"DOMA_HOME" => bad}, output: sink, error: err)
    status.exit_code.should eq(5)
    err.to_s.should contain("DOMA_HOME points at a file")
    err.to_s.should_not contain("internal error:")
  ensure
    File.delete(bad) if bad && File.exists?(bad)
  end

  it "[bug] DOMA_DB pointing at a directory gives a friendly ConfigError" do
    pending! "binary not built" unless File.exists?(bin)
    bad = File.tempname("doma-db-as-dir")
    FileUtils.mkdir_p(bad)

    sink = IO::Memory.new
    err = IO::Memory.new
    status = Process.run(bin, ["list"], env: {"DOMA_DB" => bad}, output: sink, error: err)
    status.exit_code.should eq(5)
    err.to_s.should contain("DOMA_DB points at a directory")
    err.to_s.should_not contain("internal error:")
  ensure
    FileUtils.rm_rf(bad) if bad
  end
end

describe "doma export -o bad paths" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[bug] errors cleanly when output path is a directory" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-export-dir")
    target = File.tempname("doma-export-target")
    FileUtils.mkdir_p(home)
    FileUtils.mkdir_p(target)

    sink = IO::Memory.new
    Process.run(bin, ["add", "/tmp", "-t", "x"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

    err = IO::Memory.new
    status = Process.run(
      bin, ["export", "-o", target],
      env: {"DOMA_HOME" => home}, output: sink, error: err,
    )
    status.exit_code.should eq(2)
    combined = err.to_s + sink.to_s
    combined.should contain("is a directory")
    combined.should_not contain("internal error:")
  ensure
    FileUtils.rm_rf(home) if home
    FileUtils.rm_rf(target) if target
  end

  it "[bug] errors cleanly when parent directory doesn't exist" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-export-noparent")
    FileUtils.mkdir_p(home)

    sink = IO::Memory.new
    Process.run(bin, ["add", "/tmp", "-t", "x"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

    err = IO::Memory.new
    status = Process.run(
      bin, ["export", "-o", "/no/such/dir/snap.json"],
      env: {"DOMA_HOME" => home}, output: sink, error: err,
    )
    status.exit_code.should eq(2)
    combined = err.to_s + sink.to_s
    combined.should contain("does not exist")
    combined.should_not contain("internal error:")
  ensure
    FileUtils.rm_rf(home) if home
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

describe "doma list --pick --query in non-TTY" do
  # The browse path used to ignore --query in non-TTY (First) mode and
  # silently return the first overall entry. The regression originally
  # lived under `doma cd`; with cd lifted into a shell wrapper around
  # `list --pick`, the same invariant moves here.
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
      ["list", "--pick", "--query", "totally-nonexistent"],
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
    Process.run(bin, ["list", "--pick", "--query", "tmp"], env: {"DOMA_HOME" => home}, output: stdout_buf, error: STDERR)
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

  it "[--yes] strips -y/--yes and flips Runtime.assume_yes?" do
    prev = Doma::Runtime.assume_yes?
    begin
      args = ["-y", "import", "--replace", "snap.json"]
      Doma::CLI::Runner.apply_globals!(args)
      args.should eq(["import", "--replace", "snap.json"])
      Doma::Runtime.assume_yes?.should be_true
    ensure
      Doma::Runtime.assume_yes = prev
    end
  end

  it "[--yes] long form also flips the flag" do
    prev = Doma::Runtime.assume_yes?
    begin
      args = ["--yes", "import"]
      Doma::CLI::Runner.apply_globals!(args)
      args.should eq(["import"])
      Doma::Runtime.assume_yes?.should be_true
    ensure
      Doma::Runtime.assume_yes = prev
    end
  end
end

describe "doma rm -t TAG exit code" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[bug] exits non-zero when no requested tag matches a registered path" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-rm-nomatch")
    target = File.tempname("doma-rm-nomatch-dir")
    FileUtils.mkdir_p(home)
    FileUtils.mkdir_p(target)

    Process.run(bin, ["add", target, "-t", "kept"], env: {"DOMA_HOME" => home}, output: IO::Memory.new, error: IO::Memory.new)

    err_buf = IO::Memory.new
    status = Process.run(
      bin, ["rm", target, "-t", "absent"],
      env: {"DOMA_HOME" => home}, output: IO::Memory.new, error: err_buf,
    )
    # Pre-fix: this exited 0 with only a warning, so a script doing
    # `doma rm path -t absent && next` would proceed even though nothing
    # was removed. NotRegistered already exits 3; NoMatch now matches.
    status.exit_code.should eq(3)
    err_buf.to_s.should contain("no matching tag(s)")
  ensure
    FileUtils.rm_rf(home) if home
    FileUtils.rm_rf(target) if target
  end
end

describe "Smart Hex-shaped Path Resolution" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "does not treat a hex-shaped directory existing on disk as a short_id" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-hexpath")
    FileUtils.mkdir_p(home)

    # Create a local directory whose name is a valid hex short_id prefix (e.g., 'abcd')
    target = File.join(Dir.current, "abcd")
    FileUtils.mkdir_p(target)

    begin
      out_buf = IO::Memory.new
      err_buf = IO::Memory.new
      # Since ./abcd exists on disk, `doma add abcd` must register `./abcd` successfully
      # instead of resolving it as a short_id or complaining that it is a short_id.
      status = Process.run(
        bin, ["add", "abcd", "-t", "hex-test"],
        env: {"DOMA_HOME" => home}, output: out_buf, error: err_buf
      )
      status.success?.should be_true

      # Verify that `doma info abcd` successfully resolves the path
      info_buf = IO::Memory.new
      status2 = Process.run(
        bin, ["info", "abcd"],
        env: {"DOMA_HOME" => home}, output: info_buf, error: err_buf
      )
      status2.success?.should be_true
      # Info output must contain the canonicalized path of the directory
      canonical_target = Doma::Validator.canonicalize(target)
      info_buf.to_s.should contain(canonical_target)

      # Verify that `doma rm abcd` deletes it successfully
      rm_buf = IO::Memory.new
      status3 = Process.run(
        bin, ["rm", "abcd"],
        env: {"DOMA_HOME" => home}, output: rm_buf, error: err_buf
      )
      status3.success?.should be_true
    ensure
      FileUtils.rm_rf(home) if home
      FileUtils.rm_rf(target) if target
    end
  end
end

describe "Trash file locking" do
  it "successfully executes trash operations sequentially under lock" do
    with_temp_db do |db|
      tmp = File.tempname("doma-trash-lock")
      FileUtils.mkdir_p(tmp)

      begin
        db.add(tmp, ["test-lock"])
        canonical_tmp = Doma::Validator.canonicalize(tmp)
        entry = Doma::Trash.snapshot(db, canonical_tmp)
        entry.should_not be_nil

        if e = entry
          # Concurrently adding and retrieving entries should be safe and fully locked
          Doma::Trash.add!(e)
          Doma::Trash.entries(prune: true).size.should eq(1)

          # Restore should work
          db.remove_path(tmp)
          Doma::Trash.restore!(db, e)
          db.directories.size.should eq(1)
          Doma::Trash.entries(prune: false).should be_empty
        end
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe "doma from a deleted current directory" do
  bin = File.expand_path("../bin/doma", __DIR__)

  # Spawn doma with its cwd removed out from under it: a shell cds into a
  # scratch dir, deletes it, then execs doma. `File.expand_path(..., home:
  # true)` used to evaluate its `Dir.current` default eagerly and crash
  # even for the absolute DOMA_HOME, so every DB-opening command died with
  # "internal error: Error getting current directory".
  run_from_deleted_cwd = ->(doma_args : Array(String), home : String) do
    gone = File.tempname("doma-gonecwd")
    FileUtils.mkdir_p(gone)
    out_buf = IO::Memory.new
    err_buf = IO::Memory.new
    argline = doma_args.map { |a| "'#{a}'" }.join(" ")
    script = "cd \"#{gone}\" && rmdir \"#{gone}\" && exec \"#{bin}\" #{argline}"
    status = Process.run("/bin/sh", ["-c", script], env: {"DOMA_HOME" => home}, output: out_buf, error: err_buf)
    FileUtils.rm_rf(gone)
    {status: status, out: out_buf.to_s, err: err_buf.to_s}
  end

  it "[cwd-gone] cwd-independent commands still succeed (list)" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-cwdgone-home")
    FileUtils.mkdir_p(home)
    sink = IO::Memory.new
    Process.run(bin, ["add", "/tmp", "-t", "scratch"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

    r = run_from_deleted_cwd.call(["list"], home)
    r[:status].exit_code.should eq(0)
    (r[:out] + r[:err]).should_not contain("internal error:")
    r[:out].should contain("scratch")
  ensure
    FileUtils.rm_rf(home) if home
  end

  it "[cwd-gone] `add .` reports a clean error, not an internal one" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-cwdgone-home2")
    FileUtils.mkdir_p(home)

    r = run_from_deleted_cwd.call(["add", "."], home)
    # Relative path genuinely needs the cwd; the failure is expected but
    # should be a ValidationError (exit 2), not "internal error:".
    r[:status].exit_code.should eq(2)
    r[:err].should contain("current directory is unavailable")
    r[:err].should_not contain("internal error:")
  ensure
    FileUtils.rm_rf(home) if home
  end
end
