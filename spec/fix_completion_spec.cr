require "./spec_helper"

# Regression coverage for the completion generator: each case drives
# the generated script in its real shell (zsh with stubbed compsys
# builtins) and checks the candidates it produces.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)
private ZSH_OK   = !Process.find_executable("zsh").nil?
private FISH_OK  = !Process.find_executable("fish").nil?

private def script(shell : String) : String
  res = IO::Memory.new
  Process.run(DOMA_BIN, ["setup", "completion", shell], output: res)
  res.to_s
end

# Runs `driver` under `shell` in a scratch dir holding d/plain,
# 'd/with space' and d/file.json, with isolated doma state.
private def drive(shell : String, driver : String) : Array(String)
  dir = File.tempname("doma-fixcomp")
  FileUtils.mkdir_p(File.join(dir, "w", "d", "plain"))
  FileUtils.mkdir_p(File.join(dir, "w", "d", "with space"))
  File.write(File.join(dir, "w", "d", "file.json"), "{}")
  home = File.join(dir, "home")
  FileUtils.mkdir_p(home)
  env = {
    "DOMA_HOME"   => home,
    "DOMA_DB"     => File.join(home, "doma.db"),
    "DOMA_CONFIG" => File.join(home, "config.yml"),
    "PATH"        => "#{File.dirname(DOMA_BIN)}:#{ENV["PATH"]}",
  }
  buf = IO::Memory.new
  args = shell == "fish" ? ["--no-config", "-c", driver] : ["-f", "-c", driver]
  args = ["-c", driver] if shell == "bash"
  Process.run(shell, args, output: buf, error: Process::Redirect::Close,
    env: env, chdir: File.join(dir, "w"))
  buf.to_s.lines
ensure
  FileUtils.rm_rf(dir) if dir
end

private def bash(lines : Array(String)) : Array(String)
  driver = String.build do |sb|
    sb << script("bash") << "\n"
    sb << %q(t() { COMP_LINE="$1"; COMP_POINT=${#1}; COMPREPLY=(); _doma; printf '%s|' "${COMPREPLY[@]}"; echo; }) << "\n"
    lines.each { |l| sb << "t '" << l << "'\n" }
  end
  drive("bash", driver)
end

private def zsh(lines : Array(String)) : Array(String)
  stubs = <<-'ZSH'
    compadd() { [[ $1 == -a ]] && print -r -- "${(P)2}" || print -r -- "$*"; }
    _values() { shift; print -r -- "$*"; }
    _wanted() { shift 3; "$@"; }
    _describe() { print -r -- "_describe"; }
    _path_files() { print -r -- "_path_files $*"; }
    _files() { print -r -- "_files"; }
    _normal() { print -r -- "_normal $CURRENT $words[1]"; }
    t() { words=("${(@s: :)1}"); CURRENT=${#words}; PREFIX=$words[CURRENT]; local r; r=$(_doma); print -r -- "${r//$'\n'/ }"; }
    ZSH
  driver = String.build do |sb|
    sb << "compdef() { :; }\n" << script("zsh") << "\n" << stubs << "\n"
    lines.each { |l| sb << "t '" << l << "'\n" }
  end
  drive("zsh", driver).map(&.chomp)
end

private def fish(lines : Array(String)) : Array(String)
  file = File.tempname("doma-fixcomp", ".fish")
  File.write(file, script("fish"))
  driver = String.build do |sb|
    sb << "source " << file << "\n"
    lines.each { |l| sb << "complete -C '" << l << "' | string split -f1 \\t | string join '|'; echo\n" }
  end
  drive("fish", driver).map(&.chomp).reject(&.empty?)
ensure
  File.delete(file) if file && File.exists?(file)
end

describe "completion fixes" do
  it "[#12/#32] cd is described as tag-only" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    script("zsh").should contain("'cd:Resolve a directory by tag (shell wrapper)'")
    script("fish").should_not contain("short_id")
  end

  it "[#25/#80] bash keeps paths with spaces whole and asks readline for filename handling" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    bash(["doma add d/wi", "doma import d/f"]).should eq(["d/with space|", "d/file.json|"])
    script("bash").should contain("compopt -o filenames")
  end

  it "[#31] aliases ls/mv/remove complete like their commands (bash)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    res = bash(["doma ls --pi", "doma mv d/p", "doma remove d/p"])
    res.should eq(["--pick|", "d/plain|", "d/plain|"])
  end

  it "[#60] bash doesn't re-offer action words at value positions" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    res = bash(["doma config set selector ", "doma trash restore ", "doma config "])
    res[0].should_not contain("get|")
    res[1].should_not contain("restore|")
    res[2].should eq("get|set|unset|list|edit|path|")
  end

  it "[#61] bash completes values of -p/-o and nothing for free-form flags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    bash(["doma mark -p d/p", "doma export -o d/f", "doma run --jobs "]).should eq(["d/plain|", "d/file.json|", "|"])
  end

  it "[#79] bash stops offering run flags after --" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    res = bash(["doma run sp -- cat d/f", "doma run sp -- git "])
    res[0].should eq("d/file.json|")
    res[1].should_not contain("--fail-fast")
  end

  it "[#59/#61/#79/#94/#31] zsh offers flags, shells, path values and defers past --" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "zsh not on PATH" unless ZSH_OK
    res = zsh([
      "doma status --",      # 94
      "doma add --",         # 94
      "doma trash empty --", # 59
      "doma setup install ", # 59
      "doma mark -p ",       # 61
      "doma export -o ",     # 61
      "doma run --jobs ",    # 61
      "doma run sp -- git ", # 79
      "doma mv ",            # 31
    ])
    res[0].should contain("--dirty")
    res[1].should contain("--tmp")
    res[2].should contain("--older")
    res[3].should eq("bash zsh fish")
    res[4].should eq("_path_files -/")
    res[5].should eq("_files")
    res[6].should eq("")
    res[7].should eq("_normal 2 git")
    res[8].should eq("_path_files -/")
  end

  it "[#26/#31/#59/#60/#95] fish completes paths, gates --by/--ttl/--tag and setup shells" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    pending! "fish not on PATH" unless FISH_OK
    res = fish([
      "doma add d/",               # 26
      "doma import d/f",           # 26
      "doma mark -p d/p",          # 26
      "doma export -o d/f",        # 26
      "doma prune --",             # 95
      "doma status --",            # 95
      "doma ls --pi",              # 31
      "doma setup init ",          # 59
      "doma config set selector ", # 60 (prints nothing)
    ])
    res.should eq([
      "d/plain/|d/with space/",
      "d/file.json",
      "d/plain/",
      "d/file.json",
      "--expired|--gone|--hard",
      "--dirty|--exclude|--jobs|--json|--tag",
      "--pick",
      "bash|fish|zsh",
    ])
  end
end
