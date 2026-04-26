require "./spec_helper"

# CLI invocation specs that pin the pipeline-friendly output forms. We
# spawn the actual binary so the assertions cover argv parsing, not just
# the command class internals.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)

private def with_seeded_db(&)
  home = File.tempname("doma-pipe")
  FileUtils.mkdir_p(home)
  begin
    seed = ->(args : Array(String)) {
      sink = IO::Memory.new
      Process.run(DOMA_BIN, args, env: {"DOMA_HOME" => home}, output: sink, error: sink).success?.should be_true
    }
    seed.call(["add", "/tmp", "-t", "scratch"])
    seed.call(["add", Dir.current, "-t", "crystal,cli"])
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

private def run_doma(home : String, args : Array(String)) : String
  buf = IO::Memory.new
  Process.run(DOMA_BIN, args, env: {"DOMA_HOME" => home}, output: buf, error: STDERR)
  buf.to_s
end

describe "pipeline-friendly output" do
  it "list --paths emits one path per line, terminated" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_seeded_db do |home|
      stdout = run_doma(home, ["list", "--paths"])
      lines = stdout.split('\n', remove_empty: true)
      lines.size.should eq(2)
      lines.each(&.should(start_with('/')))
    end
  end

  it "list -0 emits NUL-separated paths" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_seeded_db do |home|
      stdout = run_doma(home, ["list", "-0"])
      stdout.should_not contain('\n')
      parts = stdout.split('\0', remove_empty: true)
      parts.size.should eq(2)
    end
  end

  it "list -t crystal -0 filters and stays NUL-separated" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_seeded_db do |home|
      stdout = run_doma(home, ["list", "-t", "crystal", "-0"])
      parts = stdout.split('\0', remove_empty: true)
      parts.size.should eq(1)
    end
  end

  it "tags -0 emits NUL-separated names" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_seeded_db do |home|
      stdout = run_doma(home, ["tags", "-0"])
      stdout.should_not contain('\n')
      parts = stdout.split('\0', remove_empty: true)
      parts.sort!.should eq(["cli", "crystal", "scratch"])
    end
  end

  it "list --json is parseable JSON" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_seeded_db do |home|
      stdout = run_doma(home, ["list", "--json"])
      parsed = JSON.parse(stdout)
      parsed.as_a.size.should eq(2)
      parsed.as_a.each do |entry|
        entry["path"].as_s.should start_with('/')
        entry["tags"].as_a.should_not be_empty
      end
    end
  end
end
