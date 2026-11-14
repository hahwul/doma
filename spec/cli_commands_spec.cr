require "./spec_helper"
require "json"

# CLI-level coverage for commands whose specs to date were
# DB-layer-only or missing entirely. Each block spawns the binary so
# argv parsing, exit codes, and output channels are all exercised.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)

# Spawn helper. Returns {stdout, stderr, status}. Uses an isolated
# DOMA_HOME per call so specs can't bleed into each other.
private def run(args : Array(String), env : Hash(String, String) = {} of String => String) : NamedTuple(out: String, err: String, status: Process::Status)
  stdout_buf = IO::Memory.new
  stderr_buf = IO::Memory.new
  status = Process.run(DOMA_BIN, args, env: env, output: stdout_buf, error: stderr_buf)
  {out: stdout_buf.to_s, err: stderr_buf.to_s, status: status}
end

private def with_home(&)
  home = File.tempname("doma-cli")
  FileUtils.mkdir_p(home)
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

# Drop a few directories with known tags into doma. Used by specs that
# need a populated baseline. We pick three distinct, always-present
# directories — the user's $HOME stands in for the third slot so
# specs run on whatever machine the suite happens to land on rather
# than baking in the original author's username.
SEED_HOME_PATH = ENV["HOME"]

private def seed_home(home : String, *, with_tmp : Bool = false)
  run(["add", "/tmp", "-t", "scratch"], {"DOMA_HOME" => home})
  run(["add", "/var", "-t", "shared", "-t", "fs"], {"DOMA_HOME" => home})
  run(["add", SEED_HOME_PATH, "-t", "shared", "-t", "home"], {"DOMA_HOME" => home})
  if with_tmp
    run(["add", "/", "-t", "transient", "--ttl", "30s"], {"DOMA_HOME" => home})
  end
end

# ---------- rm ----------

describe "doma rm" do
  it "[no path] errors with 2 and points at prune for bulk cleanup" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["rm"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("path is required")
      r[:err].should contain("doma prune")
    end
  end

  it "[--gone] is no longer accepted on rm (moved to prune)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["rm", "--gone"], {"DOMA_HOME" => home})
      # OptionParser::InvalidOption surfaces as exit 1.
      r[:status].exit_code.should eq(1)
      r[:err].should contain("--gone")
    end
  end
end

# ---------- option-parser error normalization ----------

describe "doma option errors" do
  it "recasts an unknown flag in doma's voice with a --help pointer" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["list", "--frobnicate"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("unknown option '--frobnicate'")
      r[:err].should contain("doma list --help")
      # No leftover capitalized Crystal default.
      r[:err].should_not contain("Invalid option")
    end
  end

  it "reports a flag that is missing its value" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["add", ".", "--ttl"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("option '--ttl' needs a value")
      r[:err].should_not contain("Missing option")
    end
  end
end

# ---------- prune ----------

describe "doma prune" do
  it "[--gone] trashes paths that no longer exist on disk (default)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-prune-vanish")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "doomed"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(vanish)

      r = run(["prune", "--gone"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # Default sweep is reversible — entries land in the trash so
      # a briefly-unmounted disk doesn't permanently destroy tags.
      # Logger.success writes to STDOUT, not STDERR.
      r[:out].should contain("trashed 1 missing path")
      r[:out].should contain("doma trash restore")

      tr = run(["trash", "list"], {"DOMA_HOME" => home})
      # `trash list` truncates very long paths in the table — match on
      # the basename which always survives the truncation.
      tr[:out].should contain(File.basename(vanish))
    end
  end

  it "[--gone --hard] permanently deletes (skips trash)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-prune-hard-vanish")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "doomed"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(vanish)

      r = run(["prune", "--gone", "--hard", "--yes"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("pruned 1 missing path")
      r[:out].should contain("permanent")

      tr = run(["trash", "list"], {"DOMA_HOME" => home})
      tr[:out].should contain("trash is empty")
    end
  end

  it "[--gone --hard, no --yes] refuses non-interactively instead of silently deleting" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-prune-hard-vanish")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "doomed"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(vanish)

      r = run(["prune", "--gone", "--hard"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("--hard requires --yes")

      list = run(["list"], {"DOMA_HOME" => home})
      list[:out].should contain(vanish)
    end
  end

  it "[--expired] removes only expired tag rows, keeping the dirs" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      # Set TTL to 1s, sleep past it.
      run(["add", "/tmp", "-t", "fast", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds

      r = run(["prune", "--expired"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)

      # Dir is still listed (it just has no tags now), tag is gone.
      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].should_not contain("fast")
    end
  end

  it "rejects --gone --expired together" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["prune", "--gone", "--expired"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("cannot be combined")
    end
  end

  it "[no flag] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["prune"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("requires --gone or --expired")
    end
  end
end

# ---------- rm tag-name redirect ----------

describe "doma rm tag-name input" do
  it "steers the user when <raw> matches a known tag name" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-rm-tag")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "alpha"], {"DOMA_HOME" => home})

      r = run(["rm", "alpha"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("looks like a tag name")
      r[:err].should contain("-t alpha")
    ensure
      FileUtils.rm_rf(target) if target
    end
  end
end

# ---------- move pre-checks ----------

describe "doma move" do
  it "checks source registration before validating destination" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["move", "/tmp/never-was-here", "/tmp/also-not-here"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      # Pre-fix this surfaced "not a directory: /tmp/also-not-here",
      # pointing the user at the wrong arg. Source check first now.
      r[:err].should contain("path not registered")
      r[:err].should contain("/tmp/never-was-here")
    end
  end

  it "hints at --allow-missing when destination doesn't exist" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-move-from")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "x"], {"DOMA_HOME" => home})

      r = run(["move", target, "#{target}-renamed"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("not a directory")
      r[:err].should contain("--allow-missing")
    ensure
      FileUtils.rm_rf(target) if target
    end
  end

  it "echoes the canonical stored path, not the raw argument" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      src = File.tempname("doma-move-canon-src")
      dst = File.tempname("doma-move-canon-dst")
      FileUtils.mkdir_p(src)
      FileUtils.mkdir_p(dst)
      begin
        run(["add", src, "-t", "mvc"], {"DOMA_HOME" => home})
        # Trailing slash on the destination is a deterministic,
        # cross-platform difference between the raw arg and its canonical
        # form. The success line must show the collapsed canonical path —
        # the same string `list` stores — not the raw `dst/`.
        r = run(["move", src, "#{dst}/"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        stored = run(["list", "-t", "mvc", "--paths"], {"DOMA_HOME" => home})[:out].strip

        shown = r[:out].match(/moved .+ -> (.+)/).try(&.[1]).try(&.strip)
        shown.should eq(stored)
      ensure
        FileUtils.rm_rf(src)
        FileUtils.rm_rf(dst)
      end
    end
  end
end

# ---------- short_id redirects ----------

describe "doma rm/add short_id redirects" do
  it "rm <short_id> for an entry already in trash points at trash restore" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-redirect-rm")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "x"], {"DOMA_HOME" => home})
      r = run(["rm", target], {"DOMA_HOME" => home})
      sid = r[:out].match(/doma trash restore (\w+)/).try(&.[1]).to_s
      sid.empty?.should be_false

      again = run(["rm", sid], {"DOMA_HOME" => home})
      again[:status].exit_code.should eq(3)
      again[:err].should contain("not registered")
      # The pre-fix hint pointed at `doma add` which created a `./<id>`
      # canonicalize attempt — wrong direction. Verify the redirect.
      again[:err].should contain("trash restore")
    ensure
      FileUtils.rm_rf(target) if target
    end
  end

  it "add <short_id> for a trashed entry suggests trash restore" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-redirect-add")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "x"], {"DOMA_HOME" => home})
      r = run(["rm", target], {"DOMA_HOME" => home})
      sid = r[:out].match(/doma trash restore (\w+)/).try(&.[1]).to_s

      readd = run(["add", sid], {"DOMA_HOME" => home})
      readd[:status].exit_code.should eq(2)
      readd[:err].should contain("looks like a short_id")
      readd[:err].should contain("trash restore")
    ensure
      FileUtils.rm_rf(target) if target
    end
  end

  it "add <short_id> for an active entry suggests re-tag form" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-redirect-active")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "x"], {"DOMA_HOME" => home})
      info = run(["info", target, "--json"], {"DOMA_HOME" => home})
      sid = JSON.parse(info[:out])["short_id"].as_s

      r = run(["add", sid], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("looks like a short_id")
      r[:err].should contain("already registered")
    ensure
      FileUtils.rm_rf(target) if target
    end
  end
end

# ---------- info bare-name fallback ----------

describe "doma info" do
  it "falls back to substring search for bare-name input" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-info-name")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "demo"], {"DOMA_HOME" => home})

      r = run(["info", File.basename(target)], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain(target)
    ensure
      FileUtils.rm_rf(target) if target
    end
  end

  it "errors with candidate list on multiple bare-name matches" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      a = File.tempname("doma-info-multi-aaa")
      b = File.tempname("doma-info-multi-bbb")
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)
      run(["add", a, "-t", "shared"], {"DOMA_HOME" => home})
      run(["add", b, "-t", "shared"], {"DOMA_HOME" => home})

      # Both paths share the prefix "doma-info-multi" → 2 hits.
      r = run(["info", "doma-info-multi"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("multiple matches")
    ensure
      FileUtils.rm_rf(a) if a
      FileUtils.rm_rf(b) if b
    end
  end
end

# ---------- hierarchical glob hint ----------

describe "doma list / run hierarchical glob hint" do
  it "list -t <parent> hints at <parent>/* when only children exist" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "work/proj-a"], {"DOMA_HOME" => home})
      run(["add", "/var", "-t", "work/proj-b"], {"DOMA_HOME" => home})

      r = run(["list", "-t", "work"], {"DOMA_HOME" => home})
      r[:err].should contain("'work/*'")
      r[:err].should contain("work/proj-a")
    end
  end
end

# ---------- run ----------

describe "doma run" do
  it "executes the command in each tagged directory (sequential)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--", "echo", "hello"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # `String#count(s)` is set-character count, not substring count.
      # Splitting on the marker is the cheap-and-correct counter.
      (r[:out].split("hello").size - 1).should eq(2) # /var + $HOME
    end
  end

  it "[--parallel] runs concurrently and reports per-dir exit" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--parallel", "--", "true"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      (r[:err].split("(exit 0)").size - 1).should eq(2)
    end
  end

  it "[--dry-run] lists targets and the command without executing" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # `false` would make a real run exit non-zero; a dry-run must not run
      # it at all, so exit stays 0 and the command is only echoed.
      r = run(["run", "shared", "--dry-run", "--", "false"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should contain("[dry-run]")
      r[:err].should contain("would run `false`")
      # The two seeded target paths print to stdout, one per line.
      r[:out].lines.count { |l| !l.strip.empty? }.should eq(2)
    end
  end

  it "[--json] attributes each directory's stdout to its own row" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--json", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      rows = JSON.parse(r[:out]).as_a
      rows.size.should eq(2)
      rows.each do |row|
        row["exit_code"].as_i.should eq(0)
        row["dry_run"].as_bool.should be_false
        # The whole point of the mode: the captured stdout belongs to
        # the directory named in the same row, not to the sweep at large.
        row["stdout"].as_s.strip.should eq(row["path"].as_s)
        row["stderr"].as_s.should eq("")
      end
    end
  end

  it "[--json] separates a child's stderr from its stdout and keeps the exit code" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--json", "--", "sh", "-c", "echo o; echo e >&2; exit 3"],
        {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1) # at least one directory failed
      rows = JSON.parse(r[:out]).as_a
      rows.size.should eq(2)
      rows.each do |row|
        row["exit_code"].as_i.should eq(3)
        row["stdout"].as_s.should eq("o\n")
        row["stderr"].as_s.should eq("e\n")
      end
    end
  end

  it "[--json --parallel] keeps input order despite out-of-order completion" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      sequential = run(["run", "shared", "--json", "--", "pwd"], {"DOMA_HOME" => home})
      seq_paths = JSON.parse(sequential[:out]).as_a.map(&.["path"].as_s)
      # Deliberately make the *first* directory the slow one, so a
      # completion-ordered implementation would be forced to emit it
      # last. Rows must still land in the same order the sequential run
      # produced — that stability is what lets a caller zip two sweeps
      # together or diff them.
      slow = seq_paths.first
      parallel = run(["run", "shared", "--parallel", "--json", "--",
                      "sh", "-c", "[ \"$(pwd)\" = \"#{slow}\" ] && sleep 0.4; pwd"],
        {"DOMA_HOME" => home})
      par_paths = JSON.parse(parallel[:out]).as_a.map(&.["path"].as_s)
      par_paths.should eq(seq_paths)
    end
  end

  it "[--json] reports a dead path as a failed row rather than terminal noise" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      gone = File.tempname("doma-gone")
      FileUtils.mkdir_p(gone)
      run(["add", gone, "-t", "vanish"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(gone)

      r = run(["run", "vanish", "--json", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      rows = JSON.parse(r[:out]).as_a
      rows.size.should eq(1)
      rows[0]["exit_code"].as_i.should eq(127)
      # doma's own explanation lands in the row's stderr — a JSON
      # consumer shouldn't have to scrape the terminal to learn why.
      rows[0]["stderr"].as_s.should contain("no longer exists")
    end
  end

  it "[--json --dry-run] previews without an exit code" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--json", "--dry-run", "--", "false"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      rows = JSON.parse(r[:out]).as_a
      rows.size.should eq(2)
      rows.each do |row|
        row["dry_run"].as_bool.should be_true
        row["exit_code"]?.should be_nil # nothing ran, so there is none
      end
    end
  end

  it "[--json] emits no ▶/✓ chrome — the rows already carry the status" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--json", "--", "true"], {"DOMA_HOME" => home})
      r[:err].should_not contain("▶")
      r[:err].should_not contain("(exit 0)")
    end
  end

  it "[missing cmd] survives without hanging, reports 127" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--parallel", "--", "/no/such/binary"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1) # at least one failure
      r[:err].should contain("(exit 127)")
    end
  end

  it "[--fail-fast] stops sequentially on first non-zero" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--fail-fast", "--", "false"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
    end
  end

  it "exposes the entry to the child as DOMA_PATH / DOMA_NAME / DOMA_ID / DOMA_TAGS" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "fs", "--json", "--", "sh", "-c", "echo \"$DOMA_PATH|$DOMA_NAME|$DOMA_ID|$DOMA_TAGS\""],
        {"DOMA_HOME" => home})
      row = JSON.parse(r[:out]).as_a.first
      path, name, id, tags = row["stdout"].as_s.strip.split("|")
      path.should eq(row["path"].as_s)
      name.should eq(File.basename(path))
      id.size.should eq(7)
      tags.split(",").sort!.should eq(%w[fs shared])
    end
  end

  it "ends a multi-directory sweep with a tally that re-lists failures" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--", "sh", "-c", "[ \"$DOMA_PATH\" != \"#{SEED_HOME_PATH}\" ]"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("1 ok · 1 failed")
      tally = r[:err].split("1 ok · 1 failed").last
      tally.should contain("✗ #{SEED_HOME_PATH} (exit 1)")
      tally.lines.count(&.includes?("✗")).should eq(1)
    end
  end

  it "[--fail-fast] counts the directories it never reached as skipped" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--fail-fast", "--", "false"], {"DOMA_HOME" => home})
      r[:err].should contain("0 ok · 1 failed · 1 skipped")
    end
  end

  it "[--no-header] drops the tally when everything passed" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--no-header", "--", "true"], {"DOMA_HOME" => home})
      r[:err].should_not contain(" ok")
    end
  end

  it "[-q] drops the tally even when something failed" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["-q", "run", "shared", "--", "false"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should_not contain("failed")
    end
  end

  it "[gone dir] blames the missing directory, not the command" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      gone = File.tempname("doma-run-gone")
      FileUtils.mkdir_p(gone)
      run(["add", gone, "-t", "ghost"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(gone)

      r = run(["run", "ghost", "--", "true"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("directory no longer exists")
      r[:err].should contain("doma prune --gone")
      # `true` plainly exists — the old message wrongly named it.
      r[:err].should_not contain("'true'")
    end
  end

  it "[no command] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("command is required")
    end
  end

  it "[-t TAG] accepts the tag via flag as an alias for positional" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "-t", "shared", "--", "echo", "hello"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      (r[:out].split("hello").size - 1).should eq(2)
    end
  end

  it "[positional + -t] ANDs the tags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "-t", "fs", "--json", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      rows = JSON.parse(r[:out]).as_a
      rows.size.should eq(1)
      rows[0]["path"].as_s.should_not eq(SEED_HOME_PATH)
    end
  end

  it "[-x TAG] skips directories carrying the excluded tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "-x", "fs", "--json", "--", "pwd"], {"DOMA_HOME" => home})
      rows = JSON.parse(r[:out]).as_a
      rows.map(&.["path"].as_s).should eq([SEED_HOME_PATH])
    end
  end

  it "[-x glob] excludes by pattern and names the exclusion when nothing is left" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "-x", "*", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("no directories tagged 'shared', excluding '*'")
    end
  end

  it "[-x a,b] splits commas like list, so nothing excluded slips through" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "-x", "fs,home", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("excluding 'fs', 'home'")
    end
  end

  it "[empty AND of known tags] gives no did-you-mean" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "fs", "-t", "home", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should_not contain("did you mean")
    end
  end

  it "[-x ''] names the flag that got the empty value" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["status", "-x", ""], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("-x got an empty value")
    end
  end

  it "[-x only] still requires an include tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "-x", "fs", "--", "pwd"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("tag is required")
    end
  end

  it "[multiple positional tags] errors instead of silently sweeping one" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # `run work personal -- cmd` previously swept only `work`, silently
      # dropping the rest — mirror `status`, which already rejects this.
      r = run(["run", "shared", "extra", "--", "echo"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("run accepts one positional tag")
      r[:err].should contain("got 2 positional args")
    end
  end

  it "[-t TAG cmd...] (forgot --) surfaces missing-`--` not double-tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # Without a leading `--`, `echo`/`hi` would otherwise land in
      # positional_tags and trip the "both forms" rule with a misleading
      # message. The validator should prefer the actual mistake first,
      # and — since no `--` was typed — reconstruct the intended command.
      r = run(["run", "-t", "shared", "echo", "hi"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("no command to run")
      r[:err].should contain("did you mean: doma run -t shared -- echo hi")
      r[:err].should_not contain("both positionally")
    end
  end

  it "[TAG cmd...] (forgot --) reconstructs the intended invocation" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "echo", "hi"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("did you mean: doma run shared -- echo hi")
      # Don't blame a separator the user never typed.
      r[:err].should_not contain("after '--'")
    end
  end

  it "[TAG --] (empty after separator) still blames the separator" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("command is required after '--'")
    end
  end

  it "[-t '' ] surfaces the empty-tag validator" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "-t", "", "--", "echo"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("empty")
    end
  end

  it "[unknown tag] errors with 3" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "no-such-tag", "--", "echo"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
    end
  end
end

# ---------- tags ----------

describe "doma tags" do
  it "hides name tags from tags / tags --tree, keeps them in --names / --json / --all" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # `tmp` is /tmp's own basename on one directory → a name tag.
      # `scratch` (also on /tmp) and `shared` (two dirs) are real groupings.
      run(["add", "/tmp", "-t", File.basename(Doma::Validator.canonicalize("/tmp"))], {"DOMA_HOME" => home})
      name = File.basename(Doma::Validator.canonicalize("/tmp"))

      r = run(["tags"], {"DOMA_HOME" => home})
      r[:out].lines.map(&.split('\t').first).should_not contain(name)
      r[:out].should contain("scratch")
      r[:err].should contain("1 name tag hidden")

      tree = run(["tags", "--tree"], {"DOMA_HOME" => home})
      tree[:out].lines.map(&.split('\t').first).should_not contain(name)

      run(["tags", "--all"], {"DOMA_HOME" => home})[:out].should contain("#{name}\t1")
      run(["tags", "--names"], {"DOMA_HOME" => home})[:out].lines.should contain(name)
      JSON.parse(run(["tags", "--json"], {"DOMA_HOME" => home})[:out]).as_a.map(&.["name"].as_s).should contain(name)
    end
  end

  it "[default] lists tags with usage counts" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["tags"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("scratch")
      r[:out].should contain("shared\t2") # used by /var + $HOME
    end
  end

  it "[--names] outputs one name per line" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["tags", "--names"], {"DOMA_HOME" => home})
      lines = r[:out].split('\n', remove_empty: true).sort!
      lines.should eq(["fs", "home", "scratch", "shared"])
    end
  end

  it "[-0] outputs NUL-separated names (xargs-safe)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["tags", "-0"], {"DOMA_HOME" => home})
      r[:out].should_not contain('\n')
      r[:out].split('\0', remove_empty: true).sort!.should eq(["fs", "home", "scratch", "shared"])
    end
  end

  it "[--tree] groups by '/' prefix" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "work/proj-a"], {"DOMA_HOME" => home})
      run(["add", "/var", "-t", "work/proj-b"], {"DOMA_HOME" => home})
      run(["add", SEED_HOME_PATH, "-t", "home"], {"DOMA_HOME" => home})

      r = run(["tags", "--tree"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("work/")
      r[:out].should contain("├─ proj-a")
      r[:out].should contain("└─ proj-b")
      r[:out].should contain("home") # flat tag still appears
    end
  end

  it "[--json] emits valid JSON with name + count" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["tags", "--json"], {"DOMA_HOME" => home})
      parsed = JSON.parse(r[:out]).as_a
      parsed.size.should eq(4)
      parsed.first.as_h.keys.sort!.should eq(["count", "name"])
    end
  end

  it "[--tree --json] rejects conflicting output formats" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["tags", "--tree", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("mutually exclusive")
    end
  end

  it "[--names -0] are compatible (NUL is just the --names separator)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["tags", "--names", "-0"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should_not contain('\n')
    end
  end
end

# ---------- list output-flag conflicts ----------

describe "doma list output flags" do
  it "[--json --paths] rejects conflicting output formats" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "--json", "--paths"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--json is incompatible with --paths")
    end
  end

  it "[--paths -0] are compatible (NUL is just the --paths separator)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "--paths", "-0"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
    end
  end

  it "[--json] carries created_at / last_used_at so callers can window by time" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["list", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      row = JSON.parse(r[:out]).as_a.first.as_h
      row["created_at"].as_i.should be > 0
      # Never picked → the schema's "never used" sentinel, same one
      # `info` renders as "never".
      row["last_used_at"].as_i.should eq(0)
    end
  end

  it "[--json] reflects a recency bump in last_used_at" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "solo"], {"DOMA_HOME" => home})
      # A single-match --pick resolves without a prompt and stamps
      # recency on the way out — the same bump the shell `cd` wrapper
      # produces in normal use.
      run(["list", "-t", "solo", "--pick"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "solo", "--json"], {"DOMA_HOME" => home})
      row = JSON.parse(r[:out]).as_a.first.as_h
      row["last_used_at"].as_i.should be > 0
    end
  end
end

# ---------- export output-flag conflicts ----------

describe "doma export output flags" do
  it "[--json --yaml] rejects conflicting output formats" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["export", "--json", "--yaml"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("mutually exclusive")
    end
  end

  it "[--yaml] alone still selects YAML" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["export", "--yaml"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("version:")
    end
  end
end

# ---------- stats ----------

describe "doma stats" do
  it "prints a summary by default" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["stats"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("Directories:")
      r[:out].should contain("Top tags:")
      r[:out].should contain("Recent:")
    end
  end

  it "[--json] structured payload has all sections" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["stats", "--json"], {"DOMA_HOME" => home})
      parsed = JSON.parse(r[:out]).as_h
      parsed["total_directories"].as_i.should eq(3)
      parsed["total_tags"].as_i.should eq(4)
      parsed["top_tags"].as_a.size.should be > 0
      parsed["recent"].as_a.size.should be > 0
      # most_used is empty in a freshly-seeded DB (no `cd` calls yet).
      parsed["most_used"].as_a.should be_empty
    end
  end

  it "[--top --recent --used] respects custom limits" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["stats", "--top", "1", "--recent", "1", "--used", "1", "--json"], {"DOMA_HOME" => home})
      parsed = JSON.parse(r[:out]).as_h
      parsed["top_tags"].as_a.size.should eq(1)
      parsed["recent"].as_a.size.should eq(1)
    end
  end

  it "[invalid --top value] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["stats", "--top", "abc"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--top must be")
    end
  end
end

# ---------- move ----------

describe "doma move" do
  it "moves a registered path with tags intact" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      a = File.tempname("doma-mv-a")
      b = File.tempname("doma-mv-b")
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)
      begin
        run(["add", a, "-t", "x"], {"DOMA_HOME" => home})
        r = run(["move", a, b], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)

        list = run(["list", "-t", "x", "--paths"], {"DOMA_HOME" => home})
        list[:out].split('\n', remove_empty: true).should eq([Doma::Validator.canonicalize(b)])
      ensure
        FileUtils.rm_rf(a)
        FileUtils.rm_rf(b)
      end
    end
  end

  it "errors 3 when source is unknown" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["move", "/etc", "/var"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
    end
  end

  it "errors 2 when arg count is wrong" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["move", "/only/one"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("expected exactly two")
    end
  end
end

# ---------- rename ----------

describe "doma rename" do
  it "renames a tag in place" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["rename", "scratch", "throwaway"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("renamed scratch -> throwaway")
    end
  end

  it "merges into an existing tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["rename", "scratch", "shared"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("merged scratch into existing shared")
    end
  end

  it "is a noop on identical names" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["rename", "scratch", "scratch"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("no change")
    end
  end

  it "errors 3 when source tag is unknown" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["rename", "doesnt-exist", "anything"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
    end
  end

  it "errors 2 on invalid new tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["rename", "scratch", "has space"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
    end
  end
end

# ---------- setup init ----------

describe "doma setup init" do
  it "[zsh] emits a posix wrapper that intercepts cd" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "init", "zsh"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("doma() {")
    r[:out].should contain(%(if [ "$1" = "cd" ]; then))
    r[:out].should contain("builtin cd --")
    # Wrapper delegates resolution to `doma list --pick` rather than a
    # dedicated `cd` subcommand — the binary no longer ships one.
    r[:out].should contain("--pick")
    # The full-screen TUI can't have its stdout captured by $(...) (it hangs
    # under job control), so the wrapper hands it DOMA_CD_FILE, lets it draw
    # on the terminal, then cds to the path written there.
    r[:out].should contain(%(DOMA_CD_FILE="$__doma_cd_file" command doma "$@"))
    r[:out].should contain("command mktemp")
  end

  it "[bash] same wrapper as zsh" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    zsh = run(["setup", "init", "zsh"])[:out]
    bash = run(["setup", "init", "bash"])[:out]
    bash.should eq(zsh)
  end

  it "[fish] emits a fish-flavored wrapper" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "init", "fish"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("function doma")
    r[:out].should contain(%($argv[1] = "cd"))
    r[:out].should contain("--pick")
    r[:out].should contain("set -lx DOMA_CD_FILE")
  end

  it "[unsupported] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "init", "xonsh"])
    r[:status].exit_code.should eq(2)
    r[:err].should contain("unsupported shell")
  end

  it "[no shell] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "init"])
    r[:status].exit_code.should eq(2)
  end
end

# ---------- setup dispatch ----------

describe "doma setup dispatch" do
  it "[no action] prints the setup help" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("Usage: doma setup")
    r[:out].should contain("install")
    r[:out].should contain("init")
    r[:out].should contain("completion")
  end

  it "[unknown action] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "bogus"])
    r[:status].exit_code.should eq(2)
    r[:err].should contain("unknown setup action")
  end

  it "[setup doctor] redirects to top-level doctor" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "doctor"])
    r[:status].exit_code.should eq(1)
    r[:err].should contain("moved to `doma doctor`")
  end
end

# ---------- doctor (top-level) ----------

describe "doma doctor" do
  it "reports clean status on a fresh home" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["doctor"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("Paths")
      r[:out].should contain("Config")
      r[:out].should contain("Database")
    end
  end

  it "appears in --help banner under top-level commands" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["--help"])
    # `doctor` should be listed as its own row, not buried under `setup`.
    r[:out].should match(/^\s+doctor\s/m)
  end

  it "survives a malformed config.yml and reports it instead of dying" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      # `db_path` consults config.yml, so a parse failure used to abort
      # doctor with the ConfigError before any section printed — on the
      # one command users reach for when the config is broken.
      File.write(File.join(home, "config.yml"), "selector: [broken\n")
      r = run(["doctor"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("INVALID")
      r[:out].should contain("unresolved")
      r[:err].should_not contain("internal error")
    end
  end
end

# ---------- list flag combinations ----------

describe "doma list flags" do
  it "[-x TAG] drops directories carrying the tag and says so when nothing is left" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "-t", "shared", "-x", "fs", "--paths"], {"DOMA_HOME" => home})
      r[:out].lines.should eq([SEED_HOME_PATH])
      none = run(["list", "-x", "*"], {"DOMA_HOME" => home})
      none[:err].should contain("nothing left after excluding '*'")
      pick = run(["list", "-x", "*", "--pick", "--first"], {"DOMA_HOME" => home})
      pick[:err].should contain("nothing left after excluding '*'")
    end
  end

  it "[--by recent] orders by frecency" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # Bump /var so it floats to the top. `list --pick --first` is the
      # scriptable single-pick path that also stamps recency.
      run(["list", "-t", "fs", "--pick", "--first"], {"DOMA_HOME" => home})

      r = run(["list", "--by", "recent", "--paths"], {"DOMA_HOME" => home})
      first_line = r[:out].split('\n', remove_empty: true).first
      first_line.should eq(Doma::Validator.canonicalize("/var"))
    end
  end

  it "[--by recent with query] honors the sort when a text query is present" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    # Regression guard: the search path used to hard-code path order,
    # silently ignoring --by recent whenever a query was given.
    with_home do |home|
      seed_home(home)
      # Bump /var (the only 'fs'-tagged entry) so it outranks the other
      # 'shared'-tagged entry on recency while losing to it on path order.
      run(["list", "-t", "fs", "--pick", "--first"], {"DOMA_HOME" => home})

      r = run(["list", "shared", "--by", "recent", "--paths"], {"DOMA_HOME" => home})
      first_line = r[:out].split('\n', remove_empty: true).first
      first_line.should eq(Doma::Validator.canonicalize("/var"))
    end
  end

  it "[-t '' ] rejects empty tag instead of silently matching everything" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "-t", "", "--paths"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("empty")
    end
  end

  it "[-t '   '] also rejects whitespace-only tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "-t", "   ", "--paths"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("empty")
    end
  end

  it "[--check] flags missing paths with [gone]" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-list-vanish")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "transient"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(vanish)

      r = run(["list", "--check"], {"DOMA_HOME" => home})
      r[:out].should contain("[gone]")
    end
  end

  it "[--include-expired] surfaces tag rows past their TTL" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "fade", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds

      # Default list filters expired out.
      bare = run(["list"], {"DOMA_HOME" => home})
      bare[:out].should_not contain("fade")

      # --include-expired surfaces it.
      audit = run(["list", "--include-expired"], {"DOMA_HOME" => home})
      audit[:out].should contain("fade")
    end
  end

  it "[--check --json] adds an exists field" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "x"], {"DOMA_HOME" => home})
      r = run(["list", "--check", "--json"], {"DOMA_HOME" => home})
      parsed = JSON.parse(r[:out]).as_a
      parsed.first.as_h.keys.should contain("exists")
    end
  end

  it "[--by tag] groups entries under per-tag headers and (no tags) for untagged" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # An untagged entry to verify the (no tags) bucket renders last.
      bare = File.tempname("doma-bare")
      FileUtils.mkdir_p(bare)
      begin
        run(["add", bare], {"DOMA_HOME" => home})
        r = run(["list", "--by", "tag"], {"DOMA_HOME" => home})
        out = r[:out]
        out.should contain("#fs")
        out.should contain("#shared")
        out.should contain("(no tags)")
        # `shared` is on two seed entries → both should appear indented
        # under the `#shared` header. Walk lines instead of slicing the
        # raw string to keep the assertion readable. Spec runs are
        # non-TTY, so headers render as plain `#shared` (no ANSI).
        lines = out.lines
        shared_at = lines.index! { |l| l.chomp == "#shared" }
        section = lines[(shared_at + 1)..].take_while(&.starts_with?("  "))
        section.size.should eq(2)
      ensure
        FileUtils.rm_rf(bare)
      end
    end
  end

  it "[--by tag --json] returns an object keyed by tag with \"\" for untagged" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "alpha"], {"DOMA_HOME" => home})
      run(["add", "/var"], {"DOMA_HOME" => home})
      r = run(["list", "--by", "tag", "--json"], {"DOMA_HOME" => home})
      parsed = JSON.parse(r[:out]).as_h
      parsed.keys.should contain("alpha")
      parsed.keys.should contain("")
      parsed[""].as_a.first.as_h["path"].as_s.should eq(Doma::Validator.canonicalize("/var"))
    end
  end

  it "[--by tag --paths] dedups paths in tag-sorted order" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "alpha", "-t", "beta"], {"DOMA_HOME" => home})
      r = run(["list", "--by", "tag", "--paths"], {"DOMA_HOME" => home})
      r[:out].split('\n', remove_empty: true).size.should eq(1)
    end
  end

  it "[--by tag --pick] is rejected as incompatible" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "--by", "tag", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--by tag is incompatible with --pick")
    end
  end

  it "[--by bogus] rejects unknown sort with the new tag option in the message" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "--by", "bogus"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("'tag'")
    end
  end

  it "[--by tag --include-expired] surfaces a header for an expired tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "fade", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds

      # Default --by tag drops the expired tag → entry falls into (no tags).
      bare = run(["list", "--by", "tag"], {"DOMA_HOME" => home})
      bare[:out].should_not contain("#fade")
      bare[:out].should contain("(no tags)")

      # --include-expired brings the header back.
      audit = run(["list", "--by", "tag", "--include-expired"], {"DOMA_HOME" => home})
      audit[:out].should contain("#fade")
    end
  end

  it "[--by tag -t TAG] groups surviving entries under all of their tags, not just the filter" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      # /tmp carries both `keep` (the filter) and `extra`. After
      # filtering for `keep`, the entry should still render under
      # both #keep and #extra headers — `--by tag` shows every tag
      # the surviving entries actually carry.
      run(["add", "/tmp", "-t", "keep", "-t", "extra"], {"DOMA_HOME" => home})
      run(["add", "/var", "-t", "other"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "keep", "--by", "tag"], {"DOMA_HOME" => home})
      r[:out].should contain("#keep")
      r[:out].should contain("#extra")
      r[:out].should_not contain("#other")
    end
  end
end

# ---------- add flag matrix ----------

describe "doma add flags" do
  it "[-r --project-tag] registers every repo under a root, tagged by type" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      root = File.tempname("doma-add-r")
      begin
        FileUtils.mkdir_p(File.join(root, "app", ".git"))
        File.write(File.join(root, "app", "shard.yml"), "")
        FileUtils.mkdir_p(File.join(root, "plain"))
        # Overlapping roots: each repo is still added once.
        r = run(["add", "-r", root, root, "--project-tag", "-t", "work", "--json"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        rows = JSON.parse(r[:out]).as_a
        rows.map(&.["path"].as_s).should eq([Doma::Validator.canonicalize(File.join(root, "app"))])
        rows[0]["tags"].as_a.map(&.as_s).sort!.should eq(%w[crystal work])
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "[-r] on a tree with no repos is not-found (exit 3)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      root = File.tempname("doma-add-r-empty")
      FileUtils.mkdir_p(root)
      begin
        r = run(["add", "-r", root], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(3)
        r[:err].should contain("no git repos under")
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "[auto_tag.project] config turns project tags on; --no-project-tag overrides" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      dir = File.tempname("doma-add-proj")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "Cargo.toml"), "")
      begin
        run(["config", "set", "auto_tag.project", "true"], {"DOMA_HOME" => home})
        on = run(["add", dir, "-n", "--json"], {"DOMA_HOME" => home})
        JSON.parse(on[:out]).as_a[0]["tags"].as_a.map(&.as_s).should eq(["rust"])
        off = run(["add", dir, "-n", "--json", "--no-project-tag"], {"DOMA_HOME" => home})
        JSON.parse(off[:out]).as_a[0]["tags"].as_a.should be_empty
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "[--dry-run] resolves tags but writes nothing" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["add", "/tmp", "-t", "preview", "--dry-run"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("[dry-run] would add")

      list = run(["list", "--paths"], {"DOMA_HOME" => home})
      list[:out].should be_empty
    end
  end

  it "[--json] on successful add returns short_id and tags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["add", "/tmp", "-t", "json-test", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      json = JSON.parse(r[:out])
      json.as_a.size.should eq(1)
      row = json.as_a.first.as_h
      row["short_id"].as_s.size.should eq(7)
      row["path"].as_s.should contain("tmp")
      row["tags"].as_a.map(&.as_s).should eq(["json-test"])
      row["unchanged"].as_bool.should be_false
      row["dry_run"].as_bool.should be_false
    end
  end

  it "[--json] on no-change add sets unchanged: true and still returns short_id" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "once"], {"DOMA_HOME" => home})
      r = run(["add", "/tmp", "-t", "once", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      json = JSON.parse(r[:out])
      row = json.as_a.first.as_h
      row["unchanged"].as_bool.should be_true
      row["short_id"].as_s.size.should eq(7)
    end
  end

  it "[--no-auto-tag] suppresses basename tag even when config enables it" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      File.write(File.join(home, "config.yml"), "auto_tag:\n  basename: true\n")
      r = run(["add", "/tmp", "-t", "explicit", "--no-auto-tag"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)

      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      lines = tags[:out].split('\n', remove_empty: true)
      lines.should eq(["explicit"])
    end
  end

  it "[--no-git-tag] suppresses git auto-tags even when config enables it" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      File.write(File.join(home, "config.yml"), "auto_tag:\n  git: true\n")
      r = run(["add", "/tmp", "-t", "explicit", "--no-git-tag"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].split('\n', remove_empty: true).should eq(["explicit"])
    end
  end

  it "[multi-path partial failure] commits the valid ones, exits 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["add", "/tmp", "/no/such/dir", "/var", "-t", "batch"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)

      list = run(["list", "-t", "batch", "--paths"], {"DOMA_HOME" => home})
      list[:out].split('\n', remove_empty: true).size.should eq(2)
    end
  end
end

# ---------- list --pick ----------

describe "doma list --pick" do
  it "[single match] prints the path and exits 0" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "single"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "single", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].strip.should eq(REAL_TMP)
    end
  end

  it "[DOMA_CD_FILE] writes the pick there instead of stdout (shell wrapper `doma cd`)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "single"], {"DOMA_HOME" => home})
      cd_file = File.join(home, "cd")
      r = run(["list", "-t", "single", "--pick"], {"DOMA_HOME" => home, "DOMA_CD_FILE" => cd_file})
      r[:status].exit_code.should eq(0)
      r[:out].should be_empty
      File.read(cd_file).should eq(REAL_TMP)
    end
  end

  it "[zero matches] errors with 3 and a NotFound hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "missing", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
    end
  end

  it "[--pick + --json] errors as incompatible" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["list", "--pick", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("incompatible")
    end
  end

  it "[--query without --pick] is rejected" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["list", "--query", "foo"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--query requires --pick")
    end
  end
end

# ---------- import / setup install advanced ----------

describe "doma import advanced" do
  it "[--replace --yes] bypasses the confirmation prompt non-interactively" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "before"], {"DOMA_HOME" => home})

      payload = %({"version":1,"entries":[{"path":"/var","basename":"var","tags":["after"]}]})
      path = File.join(home, "snap.json")
      File.write(path, payload)

      r = run(["import", path, "--replace", "--yes"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("import replaced: 1 imported")

      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].split('\n', remove_empty: true).should eq(["after"])
    end
  end

  it "[--replace without --yes, non-tty] refuses and preserves data" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "preserve"], {"DOMA_HOME" => home})

      payload = %({"version":1,"entries":[]})
      path = File.join(home, "snap.json")
      File.write(path, payload)

      r = run(["import", path, "--replace"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("requires --yes")

      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].should contain("preserve")
    end
  end
end

describe "doma setup install advanced" do
  it "[--dry-run] never writes to the rc file" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    home = File.tempname("doma-install-dryrun")
    FileUtils.mkdir_p(home)
    begin
      r = run(["setup", "install", "zsh", "--dry-run"], {"DOMA_HOME" => home, "HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("Would append to")
      File.exists?(File.join(home, ".zshrc")).should be_false
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "[explicit shell beats $SHELL detection]" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    home = File.tempname("doma-install-override")
    FileUtils.mkdir_p(home)
    begin
      r = run(
        ["setup", "install", "fish", "--yes"],
        {"DOMA_HOME" => home, "HOME" => home, "SHELL" => "/bin/zsh"},
      )
      r[:status].exit_code.should eq(0)
      File.exists?(File.join(home, ".config/fish/config.fish")).should be_true
      File.exists?(File.join(home, ".zshrc")).should be_false
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

# ---------- mark validation ----------

describe "doma mark validation" do
  it "rejects whitespace inside a tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "has space"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("invalid")
    end
  end

  it "[no tags] hint advertises both positional and -t forms" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("requires at least one tag")
      r[:err].should contain("-t TAG")
    end
  end
end

# ---------- list --pick path-like miss ----------

describe "doma list --pick path-like miss" do
  it "[/abs/path] hints at `doma add` rather than tag suggestions" do
    # User instinct is `doma cd /some/path` to navigate; the shell
    # wrapper translates that to `list -t /some/path --pick`. Surface
    # the right next step instead of "did you mean some-tag?".
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "/var", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("to register this path")
      r[:err].should contain("doma add /var")
    end
  end

  it "[~/foo] also routes to the add hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "~/Downloads", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("doma add ~/Downloads")
    end
  end

  it "[plain typo] still uses the suggester (no add hint)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "dem", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("Did you mean")
      r[:err].should_not contain("to register this path")
    end
  end
end

# ---------- run --no-header ----------

describe "doma run --no-header" do
  it "suppresses ▶ header and ✓ footer for successful runs" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--no-header", "--", "true"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("▶")
      r[:err].should_not contain("(exit 0)")
    end
  end

  it "still surfaces failures so a partial sweep doesn't slip past" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--no-header", "--", "false"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("✗")
      r[:err].should contain("(exit 1)")
    end
  end

  it "global -q implies --no-header" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["-q", "run", "shared", "--", "true"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("▶")
    end
  end
end

# ---------- setup completion ----------

private ZSH_OK = !Process.find_executable("zsh").nil?

describe "doma setup completion" do
  it "[bash] emits a function and registers it via complete" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "bash"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("_doma()")
    r[:out].should contain("complete -F _doma doma")
    # Tag completion shells out to the binary so freshly-added tags
    # show up without a rebuild.
    r[:out].should contain("doma tags --names")
  end

  it "[bash] offers @sets only where the selector takes them, trimmed past COMP_WORDBREAKS" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    script = run(["setup", "completion", "bash"])[:out]
    # No bash-completion: `_doma` rebuilds words from COMP_LINE, so `@f`
    # and `lang:c` stay whole, and each candidate is trimmed back to the
    # text readline will actually replace.
    driver = <<-SH
      #{script}
      COMP_WORDBREAKS="@: "
      t() { COMP_LINE="$1"; COMP_POINT=${#1}; COMPREPLY=(); _doma; echo "${COMPREPLY[*]}"; }
      t "doma run @f"
      t "doma status -t lang:c"
      t "doma run "
      t "doma add -t @"
      SH
    with_home do |home|
      run(["add", "/tmp", "-t", "lang:crystal"], {"DOMA_HOME" => home})
      buf = IO::Memory.new
      Process.run("bash", ["-c", driver], output: buf, error: Process::Redirect::Close,
        env: {"DOMA_HOME" => home, "PATH" => "#{File.dirname(File.expand_path(DOMA_BIN))}:#{ENV["PATH"]}"})
      buf.to_s.lines.should eq(["failed", "crystal", "lang:crystal @failed @dirty @ahead @behind @unreleased", ""])
    end
  end

  it "[zsh/fish] add @sets for list/run/status" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    run(["setup", "completion", "zsh"])[:out].should contain("tags+=(@failed @dirty @ahead @behind @unreleased)")
    fish = run(["setup", "completion", "fish"])[:out]
    fish.should contain("__fish_seen_subcommand_from list ls run status' -s t -l tag -x -a '@failed @dirty @ahead @behind @unreleased'")
    fish.should contain("__fish_seen_subcommand_from run; and test (count (commandline -opc)) -le 2' -a '@failed @dirty @ahead @behind @unreleased'")
  end

  it "[zsh] emits a #compdef header and a tag-completion helper" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("#compdef doma")
    r[:out].should contain("doma tags --names")
    r[:out].should contain("compdef _doma doma")
  end

  it "[zsh] lists every top-level command in top_cmds (regression: prune/info/doctor missed)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)
    %w[prune info doctor].each do |cmd|
      r[:out].should contain("'#{cmd}:")
    end
  end

  it "[zsh] lists the tui command in top_cmds (regression: tui was missing)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("'tui:")
  end

  it "[bash] surfaces flags that had drifted out of COMMAND_SPEC" do
    # Regression: completion lagged the CLI — `tui`, `add --json`,
    # `prune --hard`, `stats --group-by-prefix`, and `trash --json` all
    # existed as real flags/commands but were absent from completion.
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "bash"])
    r[:status].exit_code.should eq(0)
    %w[--json --hard --group-by-prefix].each do |flag|
      r[:out].should contain(flag)
    end
  end

  it "[zsh] setup description does not falsely list doctor as a sub-action" do
    # Regression: pre-COMMAND_SPEC, zsh's setup description was
    # "install / init / doctor / completion" — doctor is its own
    # top-level command, not a setup action.
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)
    r[:out].should_not contain("setup:install / init / doctor / completion")
  end

  it "[fish] emits subcommand completions and tag value completion" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "fish"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("__fish_use_subcommand")
    r[:out].should contain("doma tags --names")
  end

  it "[fish] escapes apostrophes in command descriptions" do
    # Regression: `'Show one entry's details ...'` was emitted with an
    # unescaped apostrophe, breaking fish's single-quoted -d value.
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "fish"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("entry\\'s")
    r[:out].should_not match(/'Show one entry's/)
  end

  it "[zsh] escapes apostrophes in command descriptions" do
    # Regression: the "info" command's "entry's" description was
    # emitted with a bare, unescaped apostrophe inside a zsh
    # single-quoted `top_cmds` entry. zsh has no in-quote escape for
    # `'` (unlike fish's `\'`) — the imbalance isn't line-scoped, so it
    # silently corrupted parsing of the rest of the generated script.
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("entry'\\''s")
    r[:out].should_not match(/'info:Show one entry's/)
  end

  it "[zsh] the generated script is syntactically valid" do
    # The strongest guard against this whole class of bug: actually
    # hand the output to zsh's parser rather than asserting on specific
    # substrings.
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "zsh not on PATH" unless ZSH_OK
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)

    script = File.tempname("doma-zsh-completion", ".zsh")
    File.write(script, r[:out])
    check = Process.run("zsh", ["-n", script], output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    File.delete(script)
    check.success?.should be_true
  end

  it "[fish] emits trash long-flag completions (regression: --merge/--older missed)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "fish"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("__fish_seen_subcommand_from trash' -l merge")
    r[:out].should contain("__fish_seen_subcommand_from trash' -l older")
  end

  it "[unsupported shell] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "xonsh"])
    r[:status].exit_code.should eq(2)
    r[:err].should contain("unsupported shell")
  end

  it "[no shell] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion"])
    r[:status].exit_code.should eq(2)
    r[:err].should contain("shell is required")
  end

  it "is listed as an action in `setup --help`" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "--help"])
    r[:out].should contain("completion")
  end
end

# ---------- list --pick ambiguous auto-pick ----------

describe "doma list --pick ambiguous" do
  it "errors out when stdin is not a TTY and multiple matches need disambiguation" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home) # `shared` matches /var + $HOME
      r = run(["list", "-t", "shared", "--pick"], {"DOMA_HOME" => home})
      # Refuses to silently auto-pick from a non-interactive context
      # (the README itself recommends `cd "$(doma list -t … --pick)"`,
      # so a quiet pick of one of N matches is a footgun there).
      r[:status].exit_code.should eq(4)
      r[:err].should contain("ambiguous --pick")
      r[:err].should contain("--first")
    end
  end

  it "stays silent when only one path matches" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home) # `scratch` is only on /tmp
      r = run(["list", "-t", "scratch", "--pick"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("matches")
    end
  end

  it "--first picks deterministically without launching the picker" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["list", "-t", "shared", "--pick", "--first"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].strip.empty?.should be_false
    end
  end

  it "--first under -q stays silent" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["-q", "list", "-t", "shared", "--pick", "--first"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("matches")
    end
  end
end

# ---------- list first-run hint ----------

describe "doma list first-run hint" do
  it "[empty DB, no filters] suggests `doma add .`" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["list"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should contain("no directories registered")
      r[:err].should contain("doma add .")
    end
  end

  it "[empty DB, with filter] does NOT show the first-run hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["list", "-t", "anything"], {"DOMA_HOME" => home})
      r[:err].should_not contain("doma add .")
    end
  end

  it "[populated DB, miss] does NOT show the first-run hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "live"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "missing"], {"DOMA_HOME" => home})
      r[:err].should_not contain("doma add .")
    end
  end
end

# ---------- list expired banner & marker ----------

describe "doma list expired surfacing" do
  it "shows a banner counting expired tags hidden by default" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "fast", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds
      r = run(["list"], {"DOMA_HOME" => home})
      r[:err].should contain("hidden by TTL")
      r[:err].should contain("--include-expired")
    end
  end

  it "[--include-expired] omits the banner and renders ~expired" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "fast", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds
      r = run(["list", "--include-expired"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("hidden by TTL")
      r[:out].should contain("~expired")
    end
  end

  it "no banner when nothing has actually expired" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "live"], {"DOMA_HOME" => home})
      r = run(["list"], {"DOMA_HOME" => home})
      r[:err].should_not contain("hidden by TTL")
    end
  end

  it "[--paths] mode is silent for piping (banner not on stdout)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "fast", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds
      r = run(["list", "--paths"], {"DOMA_HOME" => home})
      # stdout must stay strictly machine-readable: only paths.
      r[:out].split('\n', remove_empty: true).each do |line|
        line.should start_with('/')
      end
    end
  end
end

# ---------- mark --path ----------

describe "doma mark --path" do
  it "[-p PATH] marks the given path instead of cwd" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "-p", "/var", "later"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      list = run(["list", "-t", "later", "--paths"], {"DOMA_HOME" => home})
      paths = list[:out].split('\n', remove_empty: true)
      paths.size.should eq(1)
      # macOS canonicalizes /var → /private/var via realpath; just match
      # whatever the canonical form is on this host.
      paths.first.should eq(Doma::Validator.canonicalize("/var"))
    end
  end

  it "[--path] long form works the same way" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "--path", "/var", "alpha", "beta"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].split('\n', remove_empty: true).sort!.should eq(["alpha", "beta"])
    end
  end

  it "[no -p] still defaults to the current directory" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "rooted"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # The cwd of the spec process is the doma project dir; we just
      # verify _something_ was registered, since the absolute path is
      # host-dependent.
      list = run(["list", "-t", "rooted", "--paths"], {"DOMA_HOME" => home})
      list[:out].lines.size.should eq(1)
    end
  end

  it "[-p MISSING_PATH] surfaces the validator error" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "-p", "/no/such/place", "tag"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("not a directory")
    end
  end

  it "[-t TAG] accepts tags via flag as an alias for positional args" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "-p", "/var", "-t", "alpha", "-t", "beta"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].split('\n', remove_empty: true).sort!.should eq(["alpha", "beta"])
    end
  end

  it "[-t TAG + positional] mixes flag and positional tags in one call" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["mark", "-p", "/var", "-t", "alpha", "beta"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].split('\n', remove_empty: true).sort!.should eq(["alpha", "beta"])
    end
  end
end

# ---------- add error message dedup ----------

describe "doma add error format" do
  it "[single missing path] no input/canonical duplication" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["add", "/no/such/dir", "-t", "x"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      # Pre-fix: "✗ /no/such/dir: not a directory: /no/such/dir"
      # Post-fix: only one mention of the path.
      lines = r[:err].lines
      err_line = lines.find!(&.includes?("not a directory"))
      err_line.scan(/\/no\/such\/dir/).size.should eq(1)
    end
  end

  it "[batch tag error] keeps input prefix when message lacks the path" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      # Tag-validation messages don't repeat the path, so the input
      # prefix is essential context in batch mode.
      r = run(["add", "/tmp", "/var", "-t", "has space"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("/tmp: tag")
      r[:err].should contain("/var: tag")
    end
  end
end

# ---------- --git-tag debug note ----------

describe "doma add --git-tag debug" do
  it "stays silent in non-git directory at default verbosity" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-nogit")
      FileUtils.mkdir_p(target)
      begin
        r = run(["add", target, "-t", "demo", "--git-tag"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        r[:err].should_not contain("--git-tag had no effect")
      ensure
        FileUtils.rm_rf(target)
      end
    end
  end

  it "[-v] surfaces the no-op note for an explicit --git-tag flag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-nogit-v")
      FileUtils.mkdir_p(target)
      begin
        r = run(["-v", "add", target, "-t", "demo", "--git-tag"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        r[:err].should contain("--git-tag had no effect")
        r[:err].should contain("not a git working tree")
      ensure
        FileUtils.rm_rf(target)
      end
    end
  end

  it "[-v, no --git-tag] silent when the flag was never asked for" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-nogit-silent")
      FileUtils.mkdir_p(target)
      begin
        r = run(["-v", "add", target, "-t", "demo"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        r[:err].should_not contain("--git-tag")
      ensure
        FileUtils.rm_rf(target)
      end
    end
  end
end

# ---------- info ----------

describe "doma info" do
  it "[registered path] shows short_id, basename, tags, timestamps" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo", "-t", "scratch"], {"DOMA_HOME" => home})
      r = run(["info", "/tmp"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # Path canonicalized; both tags rendered as #-prefixed.
      r[:out].should contain(REAL_TMP)
      r[:out].should contain("#demo")
      r[:out].should contain("#scratch")
      r[:out].should contain("basename")
      r[:out].should contain("added")
    end
  end

  it "[unregistered path] exits 3 with an `add` hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["info", "/var"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("not registered")
      r[:err].should contain("doma add /var")
    end
  end

  it "[--json] emits a structured payload with timestamps + exists" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["info", "/tmp", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      h = JSON.parse(r[:out]).as_h
      h["short_id"].as_s.size.should eq(7)
      h["path"].as_s.should eq(REAL_TMP)
      h["basename"].as_s.should eq("tmp")
      h["tags"].as_a.map(&.as_s).should eq(["demo"])
      h["created_at"].as_i.should be > 0
      h["last_used_at"].as_i.should eq(0)
      h["exists"].as_bool.should be_true
      h["found"].as_bool.should be_true
    end
  end

  it "[--json, unregistered] still emits JSON on stdout and keeps exit 3" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["info", "/var", "--json"], {"DOMA_HOME" => home})
      # Exit code is unchanged — the JSON is additive, so `&&` chains
      # and error branches behave exactly as they did before.
      r[:status].exit_code.should eq(3)
      h = JSON.parse(r[:out]).as_h
      h["found"].as_bool.should be_false
      h["input"].as_s.should eq("/var")
      h["error"].as_s.should contain("not registered")
      # The steer the text path prints survives into the payload.
      h["hint"].as_s.should contain("doma add /var")
    end
  end

  it "[--json, trashed] carries the restore hint into the payload" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      r = run(["info", "/tmp", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      h = JSON.parse(r[:out]).as_h
      h["found"].as_bool.should be_false
      h["hint"].as_s.should contain("trash restore")
    end
  end

  it "[unregistered, no --json] keeps the human error on stderr" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["info", "/var"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:out].should eq("") # nothing structured leaks into the text path
      r[:err].should contain("not registered")
    end
  end

  it "[TTL tag] surfaces expiration in the JSON map" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "fast", "--ttl", "1h"], {"DOMA_HOME" => home})
      r = run(["info", "/tmp", "--json"], {"DOMA_HOME" => home})
      h = JSON.parse(r[:out]).as_h
      h["expirations"].as_h["fast"].as_i.should be > 0
    end
  end

  it "[missing on disk] reports exists: false but still resolves the entry" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-info-vanish")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "doomed"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(vanish)

      r = run(["info", vanish], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("NO")
    end
  end
end

# ---------- info advanced (short_id / trash / relative time) ----------

describe "doma info advanced" do
  it "[short_id] resolves a full short_id to its entry" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      sid = JSON.parse(run(["list", "--json"], {"DOMA_HOME" => home})[:out]).as_a.first.as_h["short_id"].as_s

      r = run(["info", sid], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain(REAL_TMP)
      r[:out].should contain("#demo")
    end
  end

  it "[short_id prefix] resolves a unique 4-char prefix" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      sid = JSON.parse(run(["list", "--json"], {"DOMA_HOME" => home})[:out]).as_a.first.as_h["short_id"].as_s

      r = run(["info", sid[0, 4]], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain(REAL_TMP)
    end
  end

  it "[unresolved short_id] errors with 3 and dedicated message" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["info", "deadbee"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("no entry with short_id")
      # Must not nudge toward `doma add` — the user typed an id, not a path.
      r[:err].should_not contain("doma add")
    end
  end

  it "[trashed path] surfaces the trash entry with a restore hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-info-trash")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "soon-gone"], {"DOMA_HOME" => home})
      run(["rm", vanish], {"DOMA_HOME" => home}) # trash it (soft-delete)

      r = run(["info", vanish], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("not registered")
      r[:err].should contain("in trash")
      r[:err].should contain("doma trash restore")
    ensure
      FileUtils.rm_rf(vanish) if vanish
    end
  end

  it "[trashed short_id] surfaces a restore hint instead of a plain 'no entry'" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      target = File.tempname("doma-info-sid-trash")
      FileUtils.mkdir_p(target)
      run(["add", target, "-t", "sid-trash"], {"DOMA_HOME" => home})
      # Capture the short_id from list --json
      list_r = run(["list", "--json"], {"DOMA_HOME" => home})
      sid = JSON.parse(list_r[:out]).as_a.first.as_h["short_id"].as_s
      run(["rm", sid], {"DOMA_HOME" => home})

      r = run(["info", sid], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("no entry with short_id")
      r[:err].should contain("in trash")
      r[:err].should contain("doma trash restore")
    ensure
      FileUtils.rm_rf(target) if target
    end
  end

  it "[relative time] shows '<N>s ago' alongside the absolute timestamp" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["info", "/tmp"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # `added` line should carry a "(... ago)" suffix.
      added_line = r[:out].lines.find!(&.includes?("added"))
      added_line.should match(/\(\d+\w ago\)/)
    end
  end
end

# ---------- status ----------

# Whether real git repos can be built for the spawn-path tests. The
# parser logic is covered hermetically in git_status_spec; here we need
# actual repos so the command's probe → render path is exercised end to
# end. Skipped (not failed) where git is absent.
private STATUS_GIT_OK = !Process.find_executable("git").nil?

private STATUS_GIT_ENV = {
  "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t",
  "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t",
}

private def git_in(dir : String, args : Array(String))
  Process.run("git", args: ["-C", dir] + args, env: STATUS_GIT_ENV,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
end

# One commit on branch `main`; `dirty: true` leaves an untracked file so
# the working tree is unclean. Caller owns cleanup.
private def make_git_repo(prefix : String, *, dirty : Bool = false) : String
  dir = File.tempname(prefix)
  FileUtils.mkdir_p(dir)
  git_in(dir, ["init", "-q"])
  git_in(dir, ["commit", "-q", "--allow-empty", "-m", "init"])
  git_in(dir, ["branch", "-M", "main"])
  File.write(File.join(dir, "scratch.txt"), "x") if dirty
  dir
end

describe "doma export --portable / import --clone" do
  it "recreates a repo under a different home" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    origin = make_git_repo("doma-port-origin")
    old_home = File.tempname("doma-port-old")
    new_home = File.tempname("doma-port-new")
    FileUtils.mkdir_p(old_home)
    FileUtils.mkdir_p(new_home)
    begin
      snapshot = File.join(new_home, "doma.json")
      with_home do |home|
        env = {"DOMA_HOME" => home, "HOME" => old_home}
        work = File.join(old_home, "proj")
        git_in(origin, ["clone", "-q", origin, work])
        run(["add", work, "-t", "p"], env)

        # Plain export is unchanged: absolute path, no remote.
        plain = JSON.parse(run(["export"], env)[:out])["entries"][0]
        plain["path"].as_s.should eq(Doma::Validator.canonicalize(work))
        plain["remote"]?.should be_nil

        portable = run(["export", "--portable"], env)[:out]
        entry = JSON.parse(portable)["entries"][0]
        entry["path"].as_s.should eq("~/proj")
        entry["remote"].as_s.should eq(origin)
        File.write(snapshot, portable)
      end

      with_home do |home|
        env = {"DOMA_HOME" => home, "HOME" => new_home}
        target = File.join(new_home, "proj")

        hint = run(["import", snapshot], env)
        hint[:out].should contain("--clone")
        Dir.exists?(target).should be_false

        preview = run(["import", snapshot, "--clone", "--dry-run"], env)
        preview[:out].should contain("would clone #{origin}")
        Dir.exists?(target).should be_false

        r = run(["import", snapshot, "--clone"], env)
        r[:status].exit_code.should eq(0)
        Dir.exists?(File.join(target, ".git")).should be_true
        run(["list", "-t", "p", "--paths"], env)[:out].chomp.should eq(Doma::Validator.canonicalize(target))
      end
    ensure
      [origin, old_home, new_home].each { |d| FileUtils.rm_rf(d) }
    end
  end

  it "[--clone] reports a failed clone and exits non-zero, keeping the entry" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      target = File.join(home, "nope")
      snapshot = File.join(home, "snap.json")
      bad = File.join(home, "no-such-origin")
      # The nested entry must not be cloned once its parent failed: that
      # would create `nope/` and block the parent's retry.
      File.write(snapshot, {version: 2, entries: [
        {path: target, tags: ["p"], remote: bad},
        {path: File.join(target, "inner"), tags: ["q"], remote: bad},
      ]}.to_json)
      r = run(["import", snapshot, "--clone"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("2 clones failed")
      r[:err].should contain("its parent failed to clone")
      Dir.exists?(target).should be_false
      run(["list", "-t", "p", "--paths"], {"DOMA_HOME" => home})[:out].chomp.should eq(Doma::Validator.canonicalize(target))
    end
  end
end

describe "doma status" do
  it "renders clean / non-git rows and a summary across a tagged set" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      repo = make_git_repo("doma-status-clean")
      plain = File.tempname("doma-status-plain")
      FileUtils.mkdir_p(plain)
      begin
        run(["add", repo, "-t", "proj"], {"DOMA_HOME" => home})
        run(["add", plain, "-t", "proj"], {"DOMA_HOME" => home})

        r = run(["status", "proj"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        r[:out].should contain("✔ clean")
        r[:out].should contain("main")
        r[:out].should contain("not a git repo")
        r[:out].should contain("2 repos")
      ensure
        FileUtils.rm_rf(repo)
        FileUtils.rm_rf(plain)
      end
    end
  end

  it "[--dirty] keeps only repos with uncommitted changes" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      clean = make_git_repo("doma-status-d-clean")
      dirty = make_git_repo("doma-status-d-dirty", dirty: true)
      begin
        run(["add", clean, "-t", "set"], {"DOMA_HOME" => home})
        run(["add", dirty, "-t", "set"], {"DOMA_HOME" => home})

        r = run(["status", "set", "--dirty"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        r[:out].should contain(File.basename(dirty))
        r[:out].should_not contain(File.basename(clean))
        r[:out].should contain("1 dirty")
      ensure
        FileUtils.rm_rf(clean)
        FileUtils.rm_rf(dirty)
      end
    end
  end

  it "[--dirty, all clean] reports everything clean and shows no rows" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      repo = make_git_repo("doma-status-allclean")
      begin
        run(["add", repo, "-t", "tidy"], {"DOMA_HOME" => home})
        r = run(["status", "tidy", "--dirty"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        # The "all clean" note is a Logger.info line (STDOUT); no table row
        # for the repo itself.
        r[:out].should contain("clean")
        r[:out].should_not contain(File.basename(repo))
      ensure
        FileUtils.rm_rf(repo)
      end
    end
  end

  it "[--json] emits per-repo git fields" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      repo = make_git_repo("doma-status-json", dirty: true)
      begin
        run(["add", repo, "-t", "j"], {"DOMA_HOME" => home})
        r = run(["status", "j", "--json"], {"DOMA_HOME" => home})
        r[:status].exit_code.should eq(0)
        arr = JSON.parse(r[:out]).as_a
        arr.size.should eq(1)
        row = arr.first.as_h
        row["git"].as_bool.should be_true
        row["exists"].as_bool.should be_true
        row["clean"].as_bool.should be_false
        row["branch"].as_s.should eq("main")
        row["dirty"].as_i.should be >= 1
        row["untracked"].as_i.should eq(1)
      ensure
        FileUtils.rm_rf(repo)
      end
    end
  end

  it "[gone path] surfaces ✗ gone and counts it in the summary" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      repo = make_git_repo("doma-status-gone")
      run(["add", repo, "-t", "ghost"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(repo)

      r = run(["status", "ghost"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("✗ gone")
      r[:out].should contain("1 gone")
    end
  end

  it "[no tag, empty DB] hints at `doma add` and exits 0" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      r = run(["status"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # First-run hint is a Logger.info line on STDOUT.
      r[:out].should contain("nothing tracked")
      r[:out].should contain("doma add")
    end
  end

  it "[unknown tag] errors with 3 and a suggester hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["status", "no-such-tag"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("no directories tagged")
    end
  end

  it "[positional + -t] ANDs the tags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["status", "shared", "-t", "home", "--json"], {"DOMA_HOME" => home})
      JSON.parse(r[:out]).as_a.map(&.["path"].as_s).should eq([SEED_HOME_PATH])
    end
  end

  it "[-x TAG] drops excluded directories, with or without an include tag" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["status", "shared", "-x", "fs", "--json"], {"DOMA_HOME" => home})
      JSON.parse(r[:out]).as_a.map(&.["path"].as_s).should eq([SEED_HOME_PATH])
      all = run(["status", "-x", "shared", "--json"], {"DOMA_HOME" => home})
      all_paths = JSON.parse(all[:out]).as_a.map(&.["path"].as_s)
      all_paths.size.should eq(1)
      all_paths.should_not contain(SEED_HOME_PATH)
    end
  end

  it "[--jobs 0] rejects a non-positive job count (exit 2)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["status", "--jobs", "0"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--jobs must be a positive integer")
    end
  end
end

# ---------- dynamic sets ----------

describe "doma @sets" do
  it "[@failed] remembers the last run's failures, and a clean rerun empties it" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      run(["run", "shared", "--", "sh", "-c", "[ \"$DOMA_PATH\" != \"#{SEED_HOME_PATH}\" ]"], {"DOMA_HOME" => home})

      r = run(["list", "-t", "@failed", "--paths"], {"DOMA_HOME" => home})
      r[:out].lines.should eq([SEED_HOME_PATH])
      ex = run(["list", "-t", "shared", "-x", "@failed", "--paths"], {"DOMA_HOME" => home})
      ex[:out].lines.should_not contain(SEED_HOME_PATH)
      ex[:out].lines.size.should eq(1)

      retry = run(["run", "@failed", "--json", "--", "true"], {"DOMA_HOME" => home})
      JSON.parse(retry[:out]).as_a.map(&.["path"].as_s).should eq([SEED_HOME_PATH])

      empty = run(["run", "@failed", "--", "true"], {"DOMA_HOME" => home})
      empty[:status].exit_code.should eq(3)
      empty[:err].should contain("@failed is empty")
    end
  end

  it "[Ctrl-C] stops the sweep, prints the tally, and leaves the rest in @failed" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      total = run(["list", "-t", "shared", "--paths"], {"DOMA_HOME" => home})[:out].lines.size
      err = IO::Memory.new
      # Signal only doma: the first `sleep` finishes on its own, then the
      # sweep stops before starting the next directory.
      process = Process.new(DOMA_BIN, ["run", "shared", "--", "sleep", "1"],
        env: {"DOMA_HOME" => home}, output: Process::Redirect::Close, error: err)
      # The ▶ header means the trap is installed; give the first child a
      # moment to actually spawn so it counts as started, not skipped.
      200.times do
        break if err.to_s.includes?("▶")
        sleep 25.milliseconds
      end
      sleep 200.milliseconds
      process.signal(Signal::INT)
      # doma re-raises SIGINT on itself once the bookkeeping is done.
      process.wait.exit_signal?.should eq(Signal::INT)
      err.to_s.should contain("1 ok · #{total - 1} skipped")
      err.to_s.should contain("interrupted")
      r = run(["list", "-t", "@failed", "--paths"], {"DOMA_HOME" => home})
      r[:out].lines.size.should eq(total - 1)
    end
  end

  it "[--fail-fast] keeps the never-reached directories in @failed" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      run(["run", "shared", "--fail-fast", "--", "false"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "@failed", "--paths"], {"DOMA_HOME" => home})
      r[:out].lines.size.should eq(2)
    end
  end

  it "[status @dirty] behaves like --dirty" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      clean = make_git_repo("doma-sdirty-clean")
      dirty = make_git_repo("doma-sdirty-dirty", dirty: true)
      begin
        run(["add", clean, "-t", "proj"], {"DOMA_HOME" => home})
        run(["add", dirty, "-t", "proj"], {"DOMA_HOME" => home})
        r = run(["status", "proj", "-t", "@dirty", "--json"], {"DOMA_HOME" => home})
        JSON.parse(r[:out]).as_a.map(&.["path"].as_s).should eq([Doma::Validator.canonicalize(dirty)])
      ensure
        FileUtils.rm_rf(clean)
        FileUtils.rm_rf(dirty)
      end
    end
  end

  it "[--dry-run] leaves @failed alone" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      run(["run", "fs", "--", "false"], {"DOMA_HOME" => home})
      run(["run", "shared", "--dry-run", "--", "true"], {"DOMA_HOME" => home})
      r = run(["list", "-t", "@failed", "--paths"], {"DOMA_HOME" => home})
      r[:out].lines.size.should eq(1)
    end
  end

  it "[@dirty] keeps only git repos with uncommitted changes" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      clean = make_git_repo("doma-set-clean")
      dirty = make_git_repo("doma-set-dirty", dirty: true)
      begin
        run(["add", clean, "-t", "proj"], {"DOMA_HOME" => home})
        run(["add", dirty, "-t", "proj"], {"DOMA_HOME" => home})
        r = run(["run", "proj", "-t", "@dirty", "--json", "--", "true"], {"DOMA_HOME" => home})
        JSON.parse(r[:out]).as_a.map(&.["path"].as_s).should eq([Doma::Validator.canonicalize(dirty)])
      ensure
        FileUtils.rm_rf(clean)
        FileUtils.rm_rf(dirty)
      end
    end
  end

  it "[@ahead / @behind / @unreleased] select by upstream and tag distance" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "git not on PATH" unless STATUS_GIT_OK
    with_home do |home|
      origin = make_git_repo("doma-gitset-origin")
      ahead = File.tempname("doma-gitset-ahead")
      behind = File.tempname("doma-gitset-behind")
      begin
        git_in(origin, ["clone", "-q", origin, ahead])
        git_in(origin, ["clone", "-q", origin, behind])
        git_in(ahead, ["commit", "-q", "--allow-empty", "-m", "local"])
        # origin: tagged, then one commit past the tag. `behind` fetches it
        # (and the tag) without merging; `ahead` never hears about either.
        git_in(origin, ["tag", "v1"])
        git_in(origin, ["commit", "-q", "--allow-empty", "-m", "next"])
        git_in(behind, ["fetch", "-q", "--tags"])
        [origin, ahead, behind].each { |d| run(["add", d, "-t", "proj"], {"DOMA_HOME" => home}) }

        pick = ->(set : String) do
          run(["list", "-t", "proj", "-t", set, "--paths"], {"DOMA_HOME" => home})[:out].lines.map(&.chomp)
        end
        pick.call("@ahead").should eq([Doma::Validator.canonicalize(ahead)])
        pick.call("@behind").should eq([Doma::Validator.canonicalize(behind)])
        pick.call("@unreleased").should eq([Doma::Validator.canonicalize(origin)])

        # `status` answers the upstream sets from its own probe; an empty
        # result is a report, not a miss.
        st = run(["status", "proj", "-t", "@ahead", "--json"], {"DOMA_HOME" => home})
        JSON.parse(st[:out]).as_a.map(&.["path"].as_s).should eq([Doma::Validator.canonicalize(ahead)])
        none = run(["status", "proj", "-t", "@ahead", "-t", "@behind"], {"DOMA_HOME" => home})
        none[:status].exit_code.should eq(0)
        none[:out].should contain("no repos tagged 'proj' in @ahead + @behind")
      ensure
        [origin, ahead, behind].each { |d| FileUtils.rm_rf(d) }
      end
    end
  end

  it "[unknown set] fails with the known sets as a hint (exit 2)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["status", "@nope"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("unknown set '@nope'")
      r[:err].should contain("@failed")
    end
  end
end
