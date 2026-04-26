require "./spec_helper"

# These pin the exit-code contract that scripts depend on. Changing
# any of these values is a breaking change — `set -e` chains, CI
# pipelines, and the Claude Code skill all reason about doma's exit
# status.

describe Doma::Error do
  it "defaults to exit code 1" do
    Doma::Error.new("generic").exit_code.should eq(1)
  end

  it "carries the message verbatim" do
    Doma::Error.new("hello").message.should eq("hello")
  end

  it "exposes a hint when given" do
    err = Doma::Error.new("not found", hint: "try X")
    err.hint.should eq("try X")
  end

  it "has nil hint by default" do
    Doma::Error.new("plain").hint.should be_nil
  end
end

describe Doma::ValidationError do
  it "uses exit code 2" do
    Doma::ValidationError.new("bad input").exit_code.should eq(2)
  end

  it "supports a hint" do
    err = Doma::ValidationError.new("bad", hint: "use X")
    err.hint.should eq("use X")
  end
end

describe Doma::NotFoundError do
  it "uses exit code 3" do
    Doma::NotFoundError.new("missing").exit_code.should eq(3)
  end

  it "supports a hint (suggester output)" do
    err = Doma::NotFoundError.new("no tag 'foo'", hint: "Did you mean 'food'?")
    err.hint.should eq("Did you mean 'food'?")
  end
end

describe Doma::ConflictError do
  it "uses exit code 4" do
    Doma::ConflictError.new("collision").exit_code.should eq(4)
  end
end

describe Doma::ConfigError do
  it "uses exit code 5" do
    Doma::ConfigError.new("bad config").exit_code.should eq(5)
  end
end

describe Doma::ImportError do
  it "uses exit code 6" do
    Doma::ImportError.new("malformed snapshot").exit_code.should eq(6)
  end
end

# CLI integration — the runner has to actually use these codes.
describe "CLI exit codes match error classes" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "validation → 2 (e.g. add to a non-directory)" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-exit-2")
    FileUtils.mkdir_p(home)
    begin
      sink = IO::Memory.new
      status = Process.run(
        bin, ["add", "/no/such/dir/anywhere", "-t", "x"],
        env: {"DOMA_HOME" => home}, output: sink, error: sink,
      )
      status.exit_code.should eq(2)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "not-found → 3 (e.g. cd to an unknown tag)" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-exit-3")
    FileUtils.mkdir_p(home)
    begin
      sink = IO::Memory.new
      status = Process.run(
        bin, ["cd", "this-tag-does-not-exist"],
        env: {"DOMA_HOME" => home}, output: sink, error: sink,
      )
      status.exit_code.should eq(3)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "config → 5 (e.g. DOMA_HOME points at a file)" do
    pending! "binary not built" unless File.exists?(bin)
    bad = File.tempname("doma-exit-5-file")
    File.write(bad, "")
    begin
      sink = IO::Memory.new
      status = Process.run(
        bin, ["list"],
        env: {"DOMA_HOME" => bad}, output: sink, error: sink,
      )
      status.exit_code.should eq(5)
    ensure
      File.delete(bad) if File.exists?(bad)
    end
  end

  it "import → 6 (e.g. snapshot file missing)" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-exit-6")
    FileUtils.mkdir_p(home)
    begin
      sink = IO::Memory.new
      status = Process.run(
        bin, ["import", "/no/such/snapshot.json"],
        env: {"DOMA_HOME" => home}, output: sink, error: sink,
      )
      status.exit_code.should eq(6)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "unknown command → 1" do
    pending! "binary not built" unless File.exists?(bin)
    sink = IO::Memory.new
    status = Process.run(bin, ["bogus-command"], output: sink, error: sink)
    status.exit_code.should eq(1)
  end

  it "user-cancelled selection → 130 (SIGINT convention)" do
    # Hard to drive interactive cancel from a spec without a PTY harness;
    # we exercise the closest deterministic equivalent: the cancellation
    # path the runner takes when the picker reports cancelled. Skipped
    # here as it requires terminal interaction.
    pending! "needs PTY harness"
  end
end
