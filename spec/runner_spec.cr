require "./spec_helper"

# Coverage for the CLI runner's dispatch table and global flag
# stripping. apply_globals! has unit specs in regression_spec; here we
# focus on the binary-level behavior (output channels, exit codes,
# command equivalence) that the runner promises.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)

private def run(args : Array(String)) : NamedTuple(out: String, err: String, status: Process::Status)
  stdout_buf = IO::Memory.new
  stderr_buf = IO::Memory.new
  status = Process.run(DOMA_BIN, args, output: stdout_buf, error: stderr_buf)
  {out: stdout_buf.to_s, err: stderr_buf.to_s, status: status}
end

describe "Runner dispatch" do
  it "[no args] prints help and exits 0" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run([] of String)
    r[:status].exit_code.should eq(0)
    r[:out].should contain("Usage: doma <command>")
    r[:out].should contain("Commands:")
  end

  it "[--help] same output as no-args + exit 0" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    bare = run([] of String)
    helped = run(["--help"])
    helped[:status].exit_code.should eq(0)
    helped[:out].should eq(bare[:out])
  end

  it "[-h] equivalent to --help" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    long = run(["--help"])
    short = run(["-h"])
    short[:out].should eq(long[:out])
  end

  it "[help] equivalent to --help" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    long = run(["--help"])
    word = run(["help"])
    word[:out].should eq(long[:out])
  end

  it "[version / --version / -V] all print the same line" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    a = run(["version"])
    b = run(["--version"])
    c = run(["-V"])

    a[:status].exit_code.should eq(0)
    a[:out].should eq(b[:out])
    a[:out].should eq(c[:out])
    a[:out].strip.should match(/\A\d+\.\d+\.\d+/)
  end

  it "[unknown command] errors 1 and runs the suggester for near matches" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["lst"]) # close to `list` (distance 1)
    r[:status].exit_code.should eq(1)
    r[:err].should contain("unknown command 'lst'")
    r[:err].should contain("Did you mean 'list'?")
  end

  it "[unknown command] omits the hint when nothing is close enough" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["xyzqq-nothing-close"])
    r[:status].exit_code.should eq(1)
    r[:err].should contain("unknown command")
    r[:err].should_not contain("Did you mean")
  end

  it "[help banner] enumerates every dispatched command" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["--help"])
    # `cd` lives in the shell wrapper, not the binary — so it's not
    # in the dispatched-command listing. The shell-wrapper section of
    # the banner is asserted separately below.
    %w[add mark rm move tags rename list stats run export import setup].each do |cmd|
      r[:out].should contain(cmd)
    end
  end

  it "[help banner] includes Pipelines tip" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["--help"])
    r[:out].should contain("Pipelines:")
    r[:out].should contain("xargs -0")
  end

  it "[help banner] mentions the cd shell-wrap setup" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["--help"])
    r[:out].should contain("doma setup install")
    r[:out].should contain("doma cd")
  end

  it "[doma cd in binary] points at the shell wrapper" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    # Calling `doma cd` against the bare binary (no shell wrapper) must
    # not pretend to succeed — emit a clear error pointing at setup.
    r = run(["cd", "anything"])
    r[:status].exit_code.should eq(1)
    r[:err].should contain("shell wrapper")
    r[:err].should contain("doma setup install")
  end
end

describe "Runner global flags" do
  it "[-q] is stripped before subcommand parsing" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    # If `-q` weren't stripped, the version subcommand would either
    # OptionParser-error or print nothing useful. We expect quiet to
    # apply only to Logger.success — version uses STDOUT.puts directly,
    # so the version line still prints (deliberate; -q means
    # success/info, not raw STDOUT).
    r = run(["-q", "version"])
    r[:status].exit_code.should eq(0)
    r[:out].strip.should match(/\A\d+\.\d+\.\d+/)
  end

  it "[--no-color] applies before help" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    r = run(["--no-color", "--help"])
    r[:out].should_not contain("\e[")
  end

  it "[unknown global flag] falls through to the unknown-command path" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    # apply_globals! only strips known flags. An unfamiliar `--bogus-flag`
    # stays in argv and ends up as the "command" the dispatcher sees,
    # which then routes through the unknown-command handler.
    r = run(["--bogus-flag", "list"])
    r[:status].exit_code.should eq(1)
    r[:err].should contain("unknown command")
    r[:err].should contain("--bogus-flag")
  end
end
