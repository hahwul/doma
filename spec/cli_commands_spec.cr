require "./spec_helper"

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
  it "rejects --gone combined with explicit paths" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["rm", "/tmp", "--gone"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--gone cannot be combined")
    end
  end

  it "rejects --gone --expired together" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["rm", "--gone", "--expired"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("--gone and --expired cannot be combined")
    end
  end

  it "[--gone] prunes paths that no longer exist on disk" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      vanish = File.tempname("doma-rm-vanish")
      FileUtils.mkdir_p(vanish)
      run(["add", vanish, "-t", "doomed"], {"DOMA_HOME" => home})
      FileUtils.rm_rf(vanish)

      r = run(["rm", "--gone"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      # Logger.success writes to STDOUT, not STDERR — important
      # because pipelines depend on it.
      r[:out].should contain("pruned 1 missing path")
    end
  end

  it "[--expired] removes only expired tag rows, keeping the dirs" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      # Set TTL to 1s, sleep past it.
      run(["add", "/tmp", "-t", "fast", "--ttl", "1s"], {"DOMA_HOME" => home})
      sleep 1.5.seconds

      r = run(["rm", "--expired"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)

      # Dir is still listed (it just has no tags now), tag is gone.
      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      tags[:out].should_not contain("fast")
    end
  end

  it "[no path, no flag] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["rm"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("path is required")
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

  it "[no command] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["run", "shared", "--"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("command is required")
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
    r[:out].should contain("doctor")
  end

  it "[unknown action] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "bogus"])
    r[:status].exit_code.should eq(2)
    r[:err].should contain("unknown setup action")
  end

  it "[doctor] reports clean status on a fresh home" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["setup", "doctor"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("Paths")
      r[:out].should contain("Config")
      r[:out].should contain("Database")
    end
  end
end

# ---------- list flag combinations ----------

describe "doma list flags" do
  it "[--by recent] orders by frecency" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      # Bump /var so it floats to the top.
      run(["cd", "fs", "--first"], {"DOMA_HOME" => home})

      r = run(["list", "--by", "recent", "--paths"], {"DOMA_HOME" => home})
      first_line = r[:out].split('\n', remove_empty: true).first
      first_line.should eq(Doma::Validator.canonicalize("/var"))
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
end

# ---------- add flag matrix ----------

describe "doma add flags" do
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

# ---------- cd advanced ----------

describe "doma cd advanced" do
  it "[short_id exact match] resolves directly without picker" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "x"], {"DOMA_HOME" => home})
      list = run(["list", "--json"], {"DOMA_HOME" => home})
      id = JSON.parse(list[:out]).as_a.first.as_h["short_id"].as_s

      r = run(["cd", id], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].strip.should eq("/private/tmp")
    end
  end

  it "[--index 0] errors as out-of-range" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "single"], {"DOMA_HOME" => home})
      r = run(["cd", "single", "--index", "0"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("index out of range")
    end
  end

  it "[--index non-integer] errors with 2" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "single"], {"DOMA_HOME" => home})
      r = run(["cd", "single", "--index", "abc"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("must be an integer")
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
end

# ---------- cd path-like miss ----------

describe "doma cd path-like miss" do
  it "[/abs/path] hints at `doma add` rather than tag suggestions" do
    # User instinct is `doma cd /some/path` to navigate; surface the
    # right next step instead of "did you mean some-tag?".
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["cd", "/var"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("to register this path")
      r[:err].should contain("doma add /var")
    end
  end

  it "[~/foo] also routes to the add hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["cd", "~/Downloads"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("doma add ~/Downloads")
    end
  end

  it "[plain typo] still uses the suggester (no add hint)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "demo"], {"DOMA_HOME" => home})
      r = run(["cd", "dem"], {"DOMA_HOME" => home})
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

  it "[zsh] emits a #compdef header and a tag-completion helper" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "zsh"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("#compdef doma")
    r[:out].should contain("doma tags --names")
    r[:out].should contain("compdef _doma doma")
  end

  it "[fish] emits subcommand completions and tag value completion" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["setup", "completion", "fish"])
    r[:status].exit_code.should eq(0)
    r[:out].should contain("__fish_use_subcommand")
    r[:out].should contain("doma tags --names")
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

# ---------- cd ambiguous auto-pick ----------

describe "doma cd ambiguous" do
  it "warns on stderr when multiple matches auto-resolve to the first" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home) # `shared` matches /var + $HOME
      r = run(["cd", "shared"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should contain("matches 2 directories")
      r[:err].should contain("--index")
    end
  end

  it "stays silent when only one path matches" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home) # `scratch` is only on /tmp
      r = run(["cd", "scratch"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("matches")
    end
  end

  it "respects -q (quiet suppresses the advisory)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["-q", "cd", "shared"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("matches")
    end
  end

  it "explicit --index skips the advisory (user already disambiguated)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      seed_home(home)
      r = run(["cd", "shared", "--index", "1"], {"DOMA_HOME" => home})
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
      err_line = lines.find { |l| l.includes?("not a directory") }.not_nil!
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
