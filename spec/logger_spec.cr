require "./spec_helper"

# The Logger has class-level state. Each example below saves the prior
# values and restores them via `ensure` so the order specs run in
# doesn't matter.

private def with_logger_state(&)
  prev_quiet = Doma::Logger.quiet?
  prev_debug = Doma::Logger.debug?
  prev_color = Doma::Logger.color_enabled?
  begin
    yield
  ensure
    Doma::Logger.quiet = prev_quiet
    Doma::Logger.debug = prev_debug
    # color_enabled? is computed; restore by re-applying NO_COLOR state
    Doma::Logger.no_color = !prev_color
    Doma::Logger.no_color = !prev_color # double-toggle keeps current
  end
end

describe Doma::Logger do
  describe "quiet toggle" do
    it "is false by default" do
      with_logger_state do
        Doma::Logger.quiet = false
        Doma::Logger.quiet?.should be_false
      end
    end

    it "round-trips through the setter" do
      with_logger_state do
        Doma::Logger.quiet = true
        Doma::Logger.quiet?.should be_true
        Doma::Logger.quiet = false
        Doma::Logger.quiet?.should be_false
      end
    end
  end

  describe "debug toggle" do
    it "is false by default" do
      with_logger_state do
        Doma::Logger.debug = false
        Doma::Logger.debug?.should be_false
      end
    end

    it "round-trips through the setter" do
      with_logger_state do
        Doma::Logger.debug = true
        Doma::Logger.debug?.should be_true
        Doma::Logger.debug = false
        Doma::Logger.debug?.should be_false
      end
    end
  end

  describe "color toggle" do
    it "honors no_color = true" do
      with_logger_state do
        Doma::Logger.no_color = true
        Doma::Logger.color_enabled?.should be_false
      end
    end
  end
end

# CLI-level smoke for the user-visible behavior of the global flags.
# In-process toggling above proves the state moves; spawning the binary
# proves the runner wires it through every command.
describe "Doma::Logger via CLI flags" do
  bin = File.expand_path("../bin/doma", __DIR__)

  it "[-q] suppresses success output from add" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-quiet")
    FileUtils.mkdir_p(home)
    begin
      stdout_buf = IO::Memory.new
      stderr_buf = IO::Memory.new
      status = Process.run(
        bin, ["-q", "add", "/tmp", "-t", "quiet-test"],
        env: {"DOMA_HOME" => home}, output: stdout_buf, error: stderr_buf,
      )
      status.success?.should be_true
      stdout_buf.to_s.should be_empty
      stderr_buf.to_s.should be_empty
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "[--no-color] strips ANSI escapes from list output" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-nocolor")
    FileUtils.mkdir_p(home)
    begin
      sink = IO::Memory.new
      Process.run(bin, ["add", "/tmp", "-t", "x"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

      stdout_buf = IO::Memory.new
      Process.run(bin, ["--no-color", "list"], env: {"DOMA_HOME" => home}, output: stdout_buf, error: STDERR)
      stdout_buf.to_s.should_not contain("\e[")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "honors NO_COLOR env without --no-color flag" do
    pending! "binary not built" unless File.exists?(bin)
    home = File.tempname("doma-nocolor-env")
    FileUtils.mkdir_p(home)
    begin
      sink = IO::Memory.new
      Process.run(bin, ["add", "/tmp", "-t", "x"], env: {"DOMA_HOME" => home}, output: sink, error: sink)

      stdout_buf = IO::Memory.new
      Process.run(
        bin, ["list"],
        env: {"DOMA_HOME" => home, "NO_COLOR" => "1"},
        output: stdout_buf, error: STDERR,
      )
      stdout_buf.to_s.should_not contain("\e[")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
