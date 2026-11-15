require "./spec_helper"

# Regressions for the config-color group: `config edit` editor handling,
# stray args, db_path default, unwritable config, and the Colorize gate.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)

private def run(args : Array(String), home : String, env = {} of String => String?) : NamedTuple(out: String, err: String, status: Process::Status)
  stdout_buf = IO::Memory.new
  stderr_buf = IO::Memory.new
  base = {
    "DOMA_HOME" => home, "DOMA_CONFIG" => File.join(home, "config.yml"),
    "DOMA_DB" => nil, "DOMA_NO_TUI" => "1", "DOMA_CD_FILE" => nil,
    "VISUAL" => nil, "EDITOR" => nil,
  } of String => String?
  status = Process.run(DOMA_BIN, args, env: base.merge(env), output: stdout_buf, error: stderr_buf)
  {out: stdout_buf.to_s, err: stderr_buf.to_s, status: status}
end

private def with_home(&)
  home = File.tempname("doma-fix-config-color")
  FileUtils.mkdir_p(home)
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

describe "fix: config-color" do
  it "#19 config edit accepts an editor with arguments" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "edit"], home, {"EDITOR" => "true --wait"})
      r[:status].exit_code.should eq(0)
      r[:err].should_not contain("internal error")
    end
  end

  it "#22 an empty VISUAL falls back to EDITOR" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "edit"], home, {"VISUAL" => "", "EDITOR" => "true"})
      r[:status].exit_code.should eq(0)
    end
  end

  it "#21 config set rejects extra args instead of truncating" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "set", "db_path", "#{home}/my", "dir/doma.db"], home)
      r[:status].success?.should be_false
      r[:err].should contain("unexpected argument 'dir/doma.db'")
      File.exists?(File.join(home, "config.yml")).should be_false
      run(["config", "get", "selector", "extra"], home)[:status].success?.should be_false
      run(["config", "unset", "selector", "extra"], home)[:status].success?.should be_false
      run(["config", "path", "extra"], home)[:status].success?.should be_false
    end
  end

  it "#82 config get db_path prints the default when unset" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "get", "db_path"], home)
      r[:status].exit_code.should eq(0)
      r[:out].strip.should eq(File.join(home, "doma.db"))
    end
  end

  it "#82 config get db_path stays empty when DOMA_DB overrides it" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "get", "db_path"], home, {"DOMA_DB" => File.join(home, "other.db")})
      r[:status].exit_code.should eq(0)
      r[:out].strip.should eq("")
    end
  end

  it "stderr writers stay plain when stderr is redirected" do
    # A non-TTY io never gets color (barring --color), whatever STDOUT is.
    Doma::Logger.color_enabled?(IO::Memory.new).should be_false
  end

  it "#91 unwritable config location is a ConfigError, not an internal error" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      store = File.join(home, "store")
      Dir.mkdir(store)
      File.write(File.join(store, "config.yml"), "selector: auto\n")
      File.chmod(store, 0o555)
      begin
        env = {"DOMA_CONFIG" => File.join(store, "config.yml")} of String => String?
        r = run(["config", "set", "selector", "first"], home, env)
        r[:status].exit_code.should eq(5)
        r[:err].should contain("cannot write config")
        File.read(File.join(store, "config.yml")).should eq("selector: auto\n")

        env = {"DOMA_CONFIG" => File.join(store, "new.yml"), "EDITOR" => "true"} of String => String?
        r = run(["config", "edit"], home, env)
        r[:status].exit_code.should eq(5)
        r[:err].should contain("cannot write config")
      ensure
        File.chmod(store, 0o755)
      end
    end
  end

  it "#99 Logger, not Crystal's stderr-TTY default, gates color" do
    Colorize.enabled?.should be_true
    "x".colorize(:red).to_s.should contain("\e[31m")
  end
end
