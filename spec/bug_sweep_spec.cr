require "./spec_helper"
require "json"

# Regression coverage for the bug-sweep round: each example pins one
# fixed defect at the CLI boundary.

private BUG_SWEEP_BIN = File.expand_path("../bin/doma", __DIR__)

private def sweep(args : Array(String), home : String, *, chdir : String? = nil, env extra = {} of String => String)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  env = {"DOMA_HOME" => home}.merge(extra)
  status = Process.run(BUG_SWEEP_BIN, args, env: env, chdir: chdir, output: out_io, error: err_io)
  {out: out_io.to_s, err: err_io.to_s, status: status}
end

private def with_sweep_home(&)
  home = File.tempname("doma-sweep")
  FileUtils.mkdir_p(home)
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

describe "bug sweep regressions" do
  it "concurrent writers wait for the lock instead of failing" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      dirs = (1..12).map { |i| File.join(home, "d#{i}").tap { |d| Dir.mkdir(d) } }
      sweep(["list"], home)
      done = Channel(Process::Status).new
      dirs.each do |d|
        spawn { done.send(sweep(["add", d, "-t", "shared"], home)[:status]) }
      end
      dirs.size.times.map { done.receive }.count(&.success?).should eq(dirs.size)
      sweep(["list", "-t", "shared", "--paths"], home)[:out].lines.size.should eq(dirs.size)
    end
  end

  it "fails fast with a clear error when DOMA_DB is not a SQLite file" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      bogus = File.join(home, "notdb.txt")
      File.write(bogus, "hello")
      r = sweep(["list"], home, env: {"DOMA_DB" => bogus})
      r[:err].should contain("not a SQLite database")
    end
  end

  it "import writes nothing for an entry it reports as skipped" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      snap = File.join(home, "s.json")
      File.write(snap, {version: 2, entries: [
        {path: "/nonexistent/proj-x", tags: ["good", "bad tag"], expirations: {"bad tag" => 4102444800_i64}},
        {path: "rel/dir", tags: ["rel"]},
      ]}.to_json)
      r = sweep(["import", snap], home)
      (r[:out] + r[:err]).should contain("2 skipped")
      sweep(["list", "--paths"], home)[:out].should be_empty
    end
  end

  it "export rejects a positional instead of silently writing stdout" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      r = sweep(["export", "snap.json"], home)
      r[:status].exit_code.should eq(2)
      r[:err].should contain("-o FILE")
    end
  end

  it "--ttl rejects M instead of reading it as minutes" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      sweep(["add", home, "-t", "x", "--ttl", "6M"], home)[:status].exit_code.should eq(2)
      sweep(["add", home, "-t", "x", "--ttl", "6H"], home)[:status].success?.should be_true
    end
  end

  it "rename of a missing tag onto itself is not-found, not a no-op" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      sweep(["rename", "ghost", "ghost"], home)[:status].exit_code.should eq(3)
    end
  end

  it "mark -p accepts a dash-prefixed path" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      Dir.mkdir(File.join(home, "-n"))
      sweep(["mark", "-p", "-n", "foo"], home, chdir: home)[:status].success?.should be_true
      sweep(["list", "-t", "foo", "--paths"], home)[:out].should contain("/-n")
    end
  end

  it "--pick --first picks the most recently used match by default" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      %w[alpha zeta].each { |n| Dir.mkdir(File.join(home, n)) }
      sweep(["add", "alpha", "zeta", "-t", "proj"], home, chdir: home)
      sweep(["list", "zeta", "--pick"], home)
      sweep(["list", "-t", "proj", "--pick", "--first"], home)[:out].strip.should end_with("/zeta")
    end
  end

  it "soft rm keeps the row when the trash write fails" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      sweep(["add", home, "-t", "keep"], home)
      Dir.mkdir(File.join(home, "trash.jsonl"))
      sweep(["rm", home], home)[:status].success?.should be_false
      sweep(["list", "-t", "keep", "--paths"], home)[:out].should contain(home)
    end
  end

  it "run reports 128+N for a signal-killed child and keeps its output" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      sweep(["add", home, "-t", "w"], home)
      r = sweep(["run", "w", "--json", "--", "sh", "-c", "echo out; kill -TERM $$"], home)
      row = JSON.parse(r[:out]).as_a.first
      row["exit_code"].as_i.should eq(143)
      row["stdout"].as_s.should eq("out\n")
    end
  end

  it "a relative db_path resolves against the config file, not the cwd" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      elsewhere = File.join(home, "elsewhere").tap { |d| Dir.mkdir(d) }
      sweep(["config", "set", "db_path", "rel.db"], home)
      sweep(["add", home, "-t", "r"], home, chdir: elsewhere)
      File.exists?(File.join(home, "rel.db")).should be_true
      File.exists?(File.join(elsewhere, "rel.db")).should be_false
    end
  end

  it "opens DOMA_DB paths containing URI-special characters verbatim" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      %w[a#b c?d e+f g%20h].each do |name|
        dir = File.join(home, name).tap { |d| Dir.mkdir(d) }
        db = File.join(dir, "doma.db")
        sweep(["add", home, "-t", "x"], home, env: {"DOMA_DB" => db})[:status].success?.should be_true
        File.exists?(db).should be_true
      end
    end
  end

  it "status --json prints [] on an empty db" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      sweep(["status", "--json"], home)[:out].strip.should eq("[]")
    end
  end

  it "--color forces color off a TTY; an empty NO_COLOR doesn't disable it" do
    pending! "binary not built" unless File.exists?(BUG_SWEEP_BIN)
    with_sweep_home do |home|
      sweep(["--color", "add", home, "-t", "x"], home, env: {"NO_COLOR" => ""})[:out].should contain("\e[")
      sweep(["add", home, "-t", "y"], home)[:out].should_not contain("\e[")
    end
  end
end
