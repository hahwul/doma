require "./spec_helper"
require "json"

# Coverage for the soft-delete recovery path: `rm <path>` writes a
# snapshot, `doma trash list/restore/empty` reads it back. Each spec
# uses an isolated DOMA_HOME so the JSONL store can't bleed between
# cases.

private DOMA_BIN = File.expand_path("../bin/doma", __DIR__)

private def run(args : Array(String), env : Hash(String, String) = {} of String => String) : NamedTuple(out: String, err: String, status: Process::Status)
  stdout_buf = IO::Memory.new
  stderr_buf = IO::Memory.new
  status = Process.run(DOMA_BIN, args, env: env, output: stdout_buf, error: stderr_buf)
  {out: stdout_buf.to_s, err: stderr_buf.to_s, status: status}
end

private def with_home(&)
  home = File.tempname("doma-trash-spec")
  FileUtils.mkdir_p(home)
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

describe "doma rm soft-delete" do
  it "[bare rm] writes the entry to the trash and removes from db" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "scratch"], {"DOMA_HOME" => home})
      r = run(["rm", "/tmp"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("trashed")
      r[:out].should contain("doma trash restore")
      File.exists?(File.join(home, "trash.jsonl")).should be_true

      list = run(["list"], {"DOMA_HOME" => home})
      list[:out].should_not contain("/private/tmp")
      list[:out].should_not contain("/tmp")
    end
  end

  it "[--hard] bypasses the trash" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "scratch"], {"DOMA_HOME" => home})
      r = run(["rm", "/tmp", "--hard"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("permanent")
      File.exists?(File.join(home, "trash.jsonl")).should be_false
    end
  end

  it "[rm -t TAG] does not touch the trash (it's a tag op, not a delete)" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "a", "-t", "b"], {"DOMA_HOME" => home})
      r = run(["rm", "/tmp", "-t", "a"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      File.exists?(File.join(home, "trash.jsonl")).should be_false
    end
  end
end

describe "doma trash" do
  it "[list, empty] reports 'trash is empty' when nothing has been deleted" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["trash", "list"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("trash is empty")
    end
  end

  it "[list] shows trashed entries with id/age/path/tags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "scratch", "-t", "demo"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      r = run(["trash", "list"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("/private/tmp")
      r[:out].should contain("scratch")
      r[:out].should contain("demo")
    end
  end

  it "[list --json] emits a parseable JSON array with short_id, path, and tags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "scratch", "-t", "demo"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      r = run(["trash", "list", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      json = JSON.parse(r[:out])
      json.as_a.size.should eq(1)
      entry = json.as_a.first.as_h
      entry["short_id"].as_s.should_not be_empty
      entry["path"].as_s.should contain("tmp")
      entry["tags"].as_a.map(&.as_s).sort!.should eq(["demo", "scratch"])
      entry.has_key?("deleted_at").should be_true
      entry.has_key?("expirations").should be_true
    end
  end

  it "[list --json] on empty trash emits an empty JSON array" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["trash", "list", "--json"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      JSON.parse(r[:out]).as_a.size.should eq(0)
    end
  end

  it "[restore] re-inserts path with original tags" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "scratch", "-t", "demo"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})

      # Pull the short_id out of trash list (column 1).
      list = run(["trash", "list"], {"DOMA_HOME" => home})
      data_line = list[:out].lines.find!(&.includes?("/private/tmp"))
      sid = data_line.split.first

      r = run(["trash", "restore", sid], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("restored")

      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      lines = tags[:out].split('\n', remove_empty: true).sort!
      lines.should eq(["demo", "scratch"])
    end
  end

  it "[restore prefix] resolves a unique short_id prefix" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "x"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})

      list = run(["trash", "list"], {"DOMA_HOME" => home})
      data_line = list[:out].lines.find!(&.includes?("/private/tmp"))
      sid = data_line.split.first
      prefix = sid[0..2]

      r = run(["trash", "restore", prefix], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
    end
  end

  it "[restore] refuses when path is already registered" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "old"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      run(["add", "/tmp", "-t", "fresh"], {"DOMA_HOME" => home})

      list = run(["trash", "list"], {"DOMA_HOME" => home})
      data_line = list[:out].lines.find!(&.includes?("/private/tmp"))
      sid = data_line.split.first

      r = run(["trash", "restore", sid], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(4)
      r[:err].should contain("already registered")
      r[:err].should contain("--merge")
    end
  end

  it "[restore --merge] folds tags into the existing row" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "old"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      run(["add", "/tmp", "-t", "fresh"], {"DOMA_HOME" => home})

      list = run(["trash", "list"], {"DOMA_HOME" => home})
      data_line = list[:out].lines.find!(&.includes?("/private/tmp"))
      sid = data_line.split.first

      r = run(["trash", "restore", sid, "--merge"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)

      tags = run(["tags", "--names"], {"DOMA_HOME" => home})
      lines = tags[:out].split('\n', remove_empty: true).sort!
      lines.should eq(["fresh", "old"])
    end
  end

  it "[restore unknown] errors when no entry matches the prefix" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["trash", "restore", "deadbee"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(3)
      r[:err].should contain("no trash entry")
    end
  end

  it "[empty] purges the whole trash" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "x"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      r = run(["trash", "empty"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("purged 1")
      run(["trash", "list"], {"DOMA_HOME" => home})[:out].should contain("trash is empty")
    end
  end

  it "[empty --older 1d] keeps fresh entries when threshold is in the future" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      run(["add", "/tmp", "-t", "x"], {"DOMA_HOME" => home})
      run(["rm", "/tmp"], {"DOMA_HOME" => home})
      r = run(["trash", "empty", "--older", "1d"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(0)
      r[:out].should contain("nothing to purge")
      run(["trash", "list"], {"DOMA_HOME" => home})[:out].should contain("/private/tmp")
    end
  end

  it "[unknown action] errors with did-you-mean" do
    pending! "binary not built" unless File.exists?(DOMA_BIN)
    with_home do |home|
      r = run(["trash", "rstore", "abc"], {"DOMA_HOME" => home})
      r[:status].exit_code.should eq(1)
      r[:err].should contain("unknown trash action")
      r[:err].should contain("Did you mean 'restore'")
    end
  end
end
