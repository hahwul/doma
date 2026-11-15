require "./spec_helper"

# Regression coverage for the trash / prune / database-open fixes.

private BIN = File.expand_path("../bin/doma", __DIR__)

private def doma(args : Array(String), home : String, input : Process::Stdio = Process::Redirect::Close)
  so = IO::Memory.new
  se = IO::Memory.new
  st = Process.run(BIN, args, env: {"DOMA_HOME" => home, "DOMA_NO_TUI" => "1"}, input: input, output: so, error: se)
  {out: so.to_s, err: se.to_s, code: st.exit_code}
end

private def with_dir(&)
  dir = File.tempname("doma-fix-tpd")
  FileUtils.mkdir_p(dir)
  begin
    yield dir
  ensure
    Process.run("chmod", ["-R", "u+rwx", dir])
    FileUtils.rm_rf(dir)
  end
end

private def entry(path : String, at : Int64 = Time.utc.to_unix)
  Doma::Trash::Entry.new(deleted_at: at, short_id: "abc1234", path: path, basename: File.basename(path),
    last_used_at: at, tags: ["t"], expirations: {} of String => Int64)
end

describe "fix trash-prune-db" do
  it "#14/#33 dead_paths treats an unreadable path as not dead instead of raising" do
    with_temp_db do |db|
      with_dir do |dir|
        inner = File.join(dir, "locked", "inner")
        gone = File.join(dir, "gone")
        FileUtils.mkdir_p(inner)
        FileUtils.mkdir_p(gone)
        db.add(inner, ["lk"])
        db.add(gone, ["g"])
        gone_c = Doma::Validator.canonicalize(gone)
        FileUtils.rm_rf(gone)
        File.chmod(File.join(dir, "locked"), 0o000)
        db.dead_paths.map(&.path).should eq([gone_c])
      end
    end
  end

  it "#34 Database.open on a non-traversable directory raises ConfigError" do
    with_dir do |dir|
      File.chmod(dir, 0o000)
      expect_raises(Doma::ConfigError, /cannot access database path/) do
        Doma::Database.open(File.join(dir, "x.db"))
      end
    end
  end

  it "#35 existing DB in a read-only directory fails fast with ConfigError" do
    with_dir do |dir|
      path = File.join(dir, "d.db")
      Doma::Database.open(path) { }
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.chmod(dir, 0o555)
      expect_raises(Doma::ConfigError, /not writable/) { Doma::Database.open(path) }
    end
  end

  it "#35 symlinked DB in a read-only directory opens when the real dir is writable" do
    with_dir do |dir|
      Dir.mkdir(File.join(dir, "real"))
      Dir.mkdir(File.join(dir, "ro"))
      real = File.join(dir, "real", "d.db")
      Doma::Database.open(real) { }
      File.delete?("#{real}-wal")
      File.delete?("#{real}-shm")
      link = File.join(dir, "ro", "d.db")
      File.symlink(real, link)
      File.chmod(File.join(dir, "ro"), 0o555)
      begin
        Doma::Database.open(link) { }
      ensure
        File.chmod(File.join(dir, "ro"), 0o755)
      end
    end
  end

  it "#20 discard! drops only one of two identical trash lines" do
    with_temp_db do |_|
      e = entry("/x/race")
      Doma::Trash.add!(e)
      Doma::Trash.add!(e)
      Doma::Trash.discard!(e)
      Doma::Trash.entries(prune: false).size.should eq(1)
    end
  end

  it "#23 restore! reports whether it merged into an existing row" do
    with_temp_db do |db|
      with_dir do |dir|
        path = Doma::Validator.canonicalize(dir)
        Doma::Trash.restore!(db, entry(path), merge: true).should be_false
        Doma::Trash.restore!(db, entry(path), merge: true).should be_true
      end
    end
  end

  it "#93 empty!(only:) keeps entries the user wasn't shown" do
    with_temp_db do |_|
      shown = entry("/x/a")
      Doma::Trash.add!(shown)
      Doma::Trash.add!(entry("/x/b"))
      Doma::Trash.empty!(only: [shown]).should eq(1)
      Doma::Trash.entries(prune: false).map(&.path).should eq(["/x/b"])
    end
  end

  it "#92 read-only DOMA_HOME: lookups work, writes raise ConfigError" do
    with_dir do |home|
      prev = ENV["DOMA_HOME"]?
      ENV["DOMA_HOME"] = home
      begin
        File.chmod(home, 0o555)
        Doma::Trash.find_by_path("/nope").should be_nil
        expect_raises(Doma::ConfigError, /cannot use trash/) { Doma::Trash.add!(entry("/x/a")) }
      ensure
        prev ? (ENV["DOMA_HOME"] = prev) : ENV.delete("DOMA_HOME")
      end
    end
  end

  describe "CLI" do
    it "#49 repeating a prune mode flag is accepted" do
      pending! "binary not built" unless File.exists?(BIN)
      with_dir do |home|
        doma(["prune", "--gone", "--gone"], home)[:code].should eq(0)
        doma(["prune", "--expired", "--expired"], home)[:code].should eq(0)
      end
    end

    it "#48 prune rejects positional arguments" do
      pending! "binary not built" unless File.exists?(BIN)
      with_dir do |home|
        r = doma(["prune", "--gone", "/some/path"], home)
        r[:code].should eq(2)
        r[:err].should contain("no positional arguments")
      end
    end

    it "#46 multi-entry prune --gone hint is not a comma-joined id list" do
      pending! "binary not built" unless File.exists?(BIN)
      with_dir do |home|
        g1 = File.join(home, "g1")
        g2 = File.join(home, "g2")
        FileUtils.mkdir_p(g1)
        FileUtils.mkdir_p(g2)
        doma(["add", g1, g2, "-t", "g"], home)
        FileUtils.rm_rf(g1)
        FileUtils.rm_rf(g2)
        r = doma(["prune", "--gone"], home)
        r[:out].should contain("trashed 2 missing path(s)")
        r[:out].should contain("doma trash restore <id>")
        r[:out].should_not match(/restore [0-9a-f]{7},/)
      end
    end

    it "#55 trash empty / list / restore reject stray arguments" do
      pending! "binary not built" unless File.exists?(BIN)
      with_dir do |home|
        d = File.join(home, "p1")
        FileUtils.mkdir_p(d)
        doma(["add", d, "-t", "x"], home)
        doma(["rm", d], home)
        r = doma(["trash", "empty", "30d", "-y"], home)
        r[:code].should eq(2)
        r[:err].should contain("--older 30d")
        doma(["trash", "list", "bogus"], home)[:code].should eq(2)
        doma(["trash", "restore", "abc", "def"], home)[:code].should eq(2)
        doma(["trash", "list", "--json"], home)[:out].should contain(d)
      end
    end

    it "#23 trash restore --merge onto no live row doesn't claim a merge" do
      pending! "binary not built" unless File.exists?(BIN)
      with_dir do |home|
        d = File.join(home, "p1")
        FileUtils.mkdir_p(d)
        doma(["add", d, "-t", "x"], home)
        doma(["rm", d], home)
        r = doma(["trash", "restore", "--merge"], home)
        r[:code].should eq(0)
        r[:out].should_not contain("merged")
      end
    end
  end
end
