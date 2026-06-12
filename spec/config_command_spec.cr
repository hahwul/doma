require "./spec_helper"

# Coverage for `doma config get/set/unset/list/path`. Spawns the binary
# under an isolated DOMA_HOME so the disk file (config.yml) we write
# can't bleed into other specs.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)

private def run(args : Array(String), env : Hash(String, String) = {} of String => String) : NamedTuple(out: String, err: String, status: Process::Status)
  stdout_buf = IO::Memory.new
  stderr_buf = IO::Memory.new
  status = Process.run(DOMA_BIN, args, env: env, output: stdout_buf, error: stderr_buf)
  {out: stdout_buf.to_s, err: stderr_buf.to_s, status: status}
end

private def with_home(&)
  home = File.tempname("doma-config-spec")
  FileUtils.mkdir_p(home)
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

describe "doma config" do
  it "[path] prints the resolved config path under DOMA_HOME" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "path"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].strip.should eq(File.join(home, "config.yml"))
    end
  end

  it "[get] prints the default for an unset key" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "get", "auto_tag.basename"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].strip.should eq("false")
    end
  end

  it "[set] writes a bool to config.yml and get returns it" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["config", "set", "auto_tag.basename", "true"], {"DOMA_HOME" => home})
      r = run(["config", "get", "auto_tag.basename"], {"DOMA_HOME" => home})
      r[:out].strip.should eq("true")
      File.read(File.join(home, "config.yml")).should contain("basename: true")
    end
  end

  it "[set] coerces yes/no/1/0 to bool" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["config", "set", "auto_tag.git", "yes"], {"DOMA_HOME" => home})
      run(["config", "get", "auto_tag.git"], {"DOMA_HOME" => home})[:out].strip.should eq("true")
      run(["config", "set", "auto_tag.git", "0"], {"DOMA_HOME" => home})
      run(["config", "get", "auto_tag.git"], {"DOMA_HOME" => home})[:out].strip.should eq("false")
    end
  end

  it "[set] rejects invalid bool with hint" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "set", "auto_tag.git", "maybe"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("invalid bool")
      r[:err].should contain("true, false")
    end
  end

  it "[set] rejects unknown selector value with allowed list" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "set", "selector", "bogus"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("invalid value for selector")
      r[:err].should contain("auto, builtin, first")
    end
  end

  it "[set] rejects empty db_path with hint to unset" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "set", "db_path", ""], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("db_path cannot be empty")
      r[:err].should contain("doma config unset db_path")
      File.exists?(File.join(home, "config.yml")).should be_false
    end
  end

  it "[set] rejects unknown key with did-you-mean" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "set", "auto_taag.git", "true"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(2)
      r[:err].should contain("unknown config key")
      r[:err].should contain("did you mean 'auto_tag.git'")
    end
  end

  it "[unset] removes the key and reverts to default" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["config", "set", "selector", "first"], {"DOMA_HOME" => home})
      run(["config", "get", "selector"], {"DOMA_HOME" => home})[:out].strip.should eq("first")
      run(["config", "unset", "selector"], {"DOMA_HOME" => home})
      run(["config", "get", "selector"], {"DOMA_HOME" => home})[:out].strip.should eq("auto")
    end
  end

  it "[unset] cleans up the parent map when no siblings remain" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["config", "set", "auto_tag.basename", "true"], {"DOMA_HOME" => home})
      run(["config", "unset", "auto_tag.basename"], {"DOMA_HOME" => home})
      content = File.read(File.join(home, "config.yml"))
      content.should_not contain("auto_tag")
    end
  end

  it "[list] flags customized rows with * and shows source" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["config", "set", "selector", "first"], {"DOMA_HOME" => home})
      r = run(["config", "list"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("* selector")
      r[:out].should contain("(file)")
      r[:out].should contain("(default)")
    end
  end

  it "[list] reports non-string YAML keys as a ConfigError, not a crash" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      # YAML happily parses `1: foo` with an Int64 key — the old as_s
      # cast died with "internal error: cast ... failed" (exit 1).
      File.write(File.join(home, "config.yml"), "1: foo\n")
      r = run(["config", "list"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(5)
      r[:err].should contain("mapping keys must be strings")
      r[:err].should_not contain("internal error")
    end
  end

  it "[--help] prints usage with action list" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "--help"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("Usage: doma config")
      r[:out].should contain("get <key>")
      r[:out].should contain("set <key> <value>")
    end
  end

  it "[unknown action] errors with did-you-mean" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["config", "ges", "selector"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("unknown config action")
      r[:err].should contain("Did you mean 'get'")
    end
  end
end
