require "./spec_helper"
require "json"

# Regression coverage for the run/status bug group.

private FIX_RS_BIN = File.expand_path("../bin/doma", __DIR__)

private def rs_env(home : String) : Hash(String, String)
  {
    "DOMA_HOME"   => home,
    "DOMA_DB"     => File.join(home, "doma.db"),
    "DOMA_CONFIG" => File.join(home, "config.yml"),
    "DOMA_NO_TUI" => "1",
  }
end

private def rs(args : Array(String), home : String)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(FIX_RS_BIN, args, env: rs_env(home), output: out_io, error: err_io)
  {out: out_io.to_s, err: err_io.to_s, status: status}
end

private def rs_git(dir : String, *args : String)
  Process.run("git", ["-c", "user.email=a@b", "-c", "user.name=a"] + args.to_a, chdir: dir).success?.should be_true
end

private def rs_repo(path : String) : String
  FileUtils.mkdir_p(path)
  rs_git(path, "init", "-q")
  rs_git(path, "commit", "-q", "--allow-empty", "-m", "x")
  path
end

private def with_rs_home(&)
  home = File.realpath(File.tempname("doma-fix-rs").tap { |d| FileUtils.mkdir_p(d) })
  begin
    yield home
  ensure
    Process.run("chmod", ["-R", "u+rwx", home])
    FileUtils.rm_rf(home)
  end
end

describe "run/status fixes" do
  it "status survives an unstat-able tracked path (13)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      ok = rs_repo(File.join(home, "ok"))
      inner = File.join(home, "locked", "inner")
      FileUtils.mkdir_p(inner)
      rs(["add", ok, inner, "-t", "lk"], home)
      File.chmod(File.join(home, "locked"), 0o000)
      r = rs(["status", "lk"], home)
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("internal error")
      r[:out].should contain("✔ clean")
    end
  end

  it "run children get the default SIGPIPE (15)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      rs(["add", home, "-t", "t"], home)
      r = rs(["run", "t", "--no-header", "--", "sh", "-c", "yes | head -1"], home)
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("Broken pipe")
    end
  end

  it "run targets in path order, like list --paths (16)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      dirs = %w[a b c].map { |n| File.join(home, n).tap { |d| Dir.mkdir(d) } }
      rs(["add"] + dirs + ["-t", "w"], home)
      rs(["list", "-t", "w", "--pick", "c"], home)
      listed = rs(["list", "-t", "w", "--paths"], home)[:out]
      rs(["-q", "run", "w", "--dry-run", "--", "true"], home)[:out].should eq(listed)
      rows = JSON.parse(rs(["run", "w", "--json", "--", "true"], home)[:out]).as_a
      rows.map(&.["path"].as_s).should eq(listed.lines)
    end
  end

  it "run --json stays valid UTF-8 for non-UTF-8 child output (17)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      rs(["add", home, "-t", "t"], home)
      r = rs(["run", "t", "--json", "--", "printf", "\\377x"], home)
      r[:out].valid_encoding?.should be_true
      JSON.parse(r[:out])[0]["stdout"].as_s.should end_with("x")
    end
  end

  it "status aligns rows with wide characters (18)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      a = rs_repo(File.join(home, "한글"))
      b = rs_repo(File.join(home, "zz"))
      rs(["add", a, b, "-t", "st"], home)
      rows = rs(["status", "st"], home)[:out].lines.select(&.includes?("✔"))
      rows.size.should eq(2)
      cols = rows.map { |l| Doma::TUI::Text.display_width(l[0...l.index!("✔")]) }
      cols.uniq.size.should eq(1)
    end
  end

  it "missing-'--' hint keeps every selector (47)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      rs(["run", "t", "-t", "t2", "echo", "hi"], home)[:err].should contain("did you mean: doma run t -t t2 -- echo hi")
      rs(["run", "-t", "a", "-t", "b", "echo", "hi"], home)[:err].should contain("did you mean: doma run -t a -t b -- echo hi")
      rs(["run", "t", "-x", "old", "echo", "hi"], home)[:err].should contain("did you mean: doma run t -x old -- echo hi")
      rs(["run", "-t", "git", "git", "pull"], home)[:err].should contain("did you mean: doma run -t git -- git pull")
      rs(["run", "-x", "old", "t", "-t", "t2", "echo", "hi"], home)[:err].should contain("did you mean: doma run t -t t2 -x old -- echo hi")
      rs(["run", "--parallel", "--jobs", "4", "t", "-t", "t2", "echo", "hi"], home)[:err].should contain("did you mean: doma run t -t t2 -- echo hi")
    end
  end

  it "status probe leaves .git/index alone (50)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      repo = File.join(home, "r")
      FileUtils.mkdir_p(repo)
      rs_git(repo, "init", "-q")
      File.write(File.join(repo, "g"), "x")
      rs_git(repo, "add", "g")
      rs_git(repo, "commit", "-q", "-m", "x")
      rs(["add", repo, "-t", "t"], home)
      index = File.join(repo, ".git", "index")
      old = Time.utc - 1.hour
      File.touch(index, old)
      File.touch(File.join(repo, "g")) # stale stat info → git would refresh
      rs(["status", "t"], home)[:status].exit_code.should eq(0)
      File.info(index).modification_time.to_unix.should eq(old.to_unix)
    end
  end

  it "status reports a git spawn failure instead of 'not a git repo' (73)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      rs(["add", home, "-t", "g"], home)[:status].success?.should be_true
      # Pass the PATH lookup and fail during spawn with EACCES: the
      # executable script points to a non-executable interpreter.
      git = File.join(home, "git")
      File.write(git, "#!/dev/null\n")
      File.chmod(git, 0o755)
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(FIX_RS_BIN, ["status", "g"],
        env: rs_env(home).merge({"PATH" => home}), output: out_io, error: err_io)
      out_io.to_s.should_not contain("not a git repo")
      status.success?.should be_false
      err_io.to_s.should contain("could not run git")
    end
  end

  it "run on an unenterable dir blames the dir, not the command (51)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      locked = File.join(home, "locked")
      Dir.mkdir(locked)
      rs(["add", locked, "-t", "lk"], home)
      File.chmod(locked, 0o000)
      r = rs(["run", "lk", "--", "true"], home)
      r[:err].should contain("cannot enter directory")
      r[:err].should_not contain("'true'")
    end
  end

  it "--dry-run preview shell-quotes the command (52)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      rs(["add", home, "-t", "t"], home)
      r = rs(["run", "t", "--dry-run", "--", "sh", "-c", %(rm -rf "x y")], home)
      r[:err].should contain(%(would run `sh -c 'rm -rf "x y"'`))
    end
  end

  it "a second Ctrl-C under --json keeps passed dirs out of @failed (88)" do
    pending! "binary not built" unless File.exists?(FIX_RS_BIN)
    with_rs_home do |home|
      a = File.join(home, "a").tap { |d| Dir.mkdir(d) }
      b = File.join(home, "b").tap { |d| Dir.mkdir(d) }
      rs(["add", a, b, "-t", "ww"], home)
      process = Process.new(FIX_RS_BIN, ["run", "ww", "--json", "--", "sh", "-c", %([ "$DOMA_NAME" = a ] || sleep 3)],
        env: rs_env(home), output: Process::Redirect::Close, error: Process::Redirect::Close)
      sleep 1.second
      process.signal(Signal::INT)
      sleep 300.milliseconds
      process.signal(Signal::INT)
      process.wait
      rs(["list", "-t", "@failed", "--paths"], home)[:out].lines.should eq([b])
    end
  end
end
