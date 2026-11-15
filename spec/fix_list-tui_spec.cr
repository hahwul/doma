require "./spec_helper"

# Regressions for the list/TUI bug group. CLI cases shell out to bin/doma
# with every DOMA_* path pinned under a temp home.

private FIX_LT_BIN = File.expand_path("../bin/doma", __DIR__)

private def lt_run(args : Array(String), home : String, *, chdir : String? = nil)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  env = {
    "DOMA_HOME"    => home,
    "DOMA_DB"      => File.join(home, "doma.db"),
    "DOMA_CONFIG"  => File.join(home, "config.yml"),
    "DOMA_NO_TUI"  => "1",
    "DOMA_CD_FILE" => nil,
    "NO_COLOR"     => "1",
  }
  status = Process.run(FIX_LT_BIN, args, env: env, chdir: chdir, output: out_io, error: err_io)
  {out: out_io.to_s, err: err_io.to_s, status: status}
end

private def with_lt_home(&)
  home = File.tempname("doma-fix-lt")
  FileUtils.mkdir_p(home)
  begin
    yield File.realpath(home)
  ensure
    FileUtils.rm_rf(home)
  end
end

describe "list/tui fixes" do
  describe "Database#search (#6)" do
    it "matches an NFD-stored path from an NFC query, and folds non-ASCII case" do
      with_temp_db do |db|
        nfd = "/x/#{"프로젝트".unicode_normalize(:nfd)}"
        db.add(nfd, [] of String, validate_path: false)
        db.add("/x/école", [] of String, validate_path: false)
        db.search("프로젝트").map(&.path).should eq([nfd])
        db.search("ÉCOLE").map(&.path).should eq(["/x/école"])
        db.search("100%").should be_empty
      end
    end
  end

  describe "Suggester.tag_hint_for (#85/#98)" do
    it "suggests ** when only deeper children exist" do
      Doma::Suggester.tag_hint_for("team", ["team/proj/api"])
        .should eq("did you mean 'team/**'? (matches team/proj/api)")
    end

    it "keeps * and samples only one-level children when some exist" do
      Doma::Suggester.tag_hint_for("work", ["work/a/deep", "work/b"])
        .should eq("did you mean 'work/*'? (matches work/b)")
    end
  end

  describe "doma list" do
    it "scopes the TTL footer to the filter, and shows it when an expired tag empties the result (#8)" do
      pending! "binary not built" unless File.exists?(FIX_LT_BIN)
      with_lt_home do |home|
        kr = File.join(home, "kr").tap { |d| Dir.mkdir(d) }
        old = File.join(home, "old").tap { |d| Dir.mkdir(d) }
        Doma::Database.open(File.join(home, "doma.db")) do |db|
          db.add(kr, ["kr"])
          db.add(old, ["old"], expires_at: Time.utc.to_unix - 100)
        end
        lt_run(["list", "-t", "kr"], home)[:err].should_not contain("hidden by TTL")
        r = lt_run(["list", "-t", "old"], home)
        r[:err].should contain("no directories tagged 'old'")
        r[:err].should contain("1 tag hidden by TTL")
        lt_run(["list"], home)[:err].should contain("1 tag hidden by TTL")
      end
    end

    it "drops both footers under -q (#11)" do
      pending! "binary not built" unless File.exists?(FIX_LT_BIN)
      with_lt_home do |home|
        gone = File.join(home, "gone").tap { |d| Dir.mkdir(d) }
        Doma::Database.open(File.join(home, "doma.db")) do |db|
          db.add(gone, ["g"], expires_at: Time.utc.to_unix + 3600)
          db.add(gone, ["e"], expires_at: Time.utc.to_unix - 100)
        end
        Dir.delete(gone)
        lt_run(["list"], home)[:err].should contain("path is missing")
        r = lt_run(["-q", "list"], home)
        r[:err].should_not contain("hidden by TTL")
        r[:err].should_not contain("missing")
      end
    end

    it "names -x when -x gets an empty value (#37)" do
      pending! "binary not built" unless File.exists?(FIX_LT_BIN)
      with_lt_home do |home|
        lt_run(["list", "-x", ""], home)[:err].should contain("-x got an empty value")
      end
    end

    it "does not crash on a path it cannot stat (#43)" do
      pending! "binary not built" unless File.exists?(FIX_LT_BIN)
      with_lt_home do |home|
        inner = File.join(home, "locked", "inner").tap { |d| FileUtils.mkdir_p(d) }
        lt_run(["add", inner, "-t", "lk"], home)
        File.chmod(File.join(home, "locked"), 0o000)
        begin
          [["list"], ["list", "--check"], ["list", "-t", "lk", "--json", "--check"]].each do |args|
            r = lt_run(args, home)
            r[:err].should_not contain("internal error")
            r[:status].success?.should be_true
          end
        ensure
          File.chmod(File.join(home, "locked"), 0o755)
        end
      end
    end

    it "does not tell the user to add a path that is already registered (#86)" do
      pending! "binary not built" unless File.exists?(FIX_LT_BIN)
      with_lt_home do |home|
        Dir.mkdir(File.join(home, "alpha"))
        lt_run(["add", "alpha", "-t", "x"], home, chdir: home)
        r = lt_run(["list", "-t", "./alpha", "--pick"], home, chdir: home)
        r[:status].exit_code.should eq(3)
        r[:err].should contain("already registered")
        r[:err].should contain("#x")
        r[:err].should_not contain("doma add ./alpha\n")
      end
    end
  end
end
