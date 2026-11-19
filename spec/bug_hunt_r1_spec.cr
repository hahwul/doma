require "./spec_helper"
require "json"

# Regression coverage for bug-hunt round 1: each example pins one fixed
# defect at the CLI boundary.

private R1_BIN = File.expand_path("../bin/doma", __DIR__)

private def r1(args : Array(String), home : String, *, env extra = {} of String => String)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(R1_BIN, args, env: {"DOMA_HOME" => home}.merge(extra), output: out_io, error: err_io)
  {out: out_io.to_s, err: err_io.to_s, status: status}
end

# A scratch dir; DOMA_HOME is `<dir>/home` and deliberately NOT created,
# so the first command in each example is a true first run.
private def with_r1_dir(&)
  dir = File.tempname("doma-r1")
  FileUtils.mkdir_p(dir)
  begin
    yield File.realpath(dir), File.join(File.realpath(dir), "home")
  ensure
    File.chmod(File.join(dir, "locked"), 0o755) if Dir.exists?(File.join(dir, "locked"))
    FileUtils.rm_rf(dir)
  end
end

private def strip_ansi(text : String) : String
  text.gsub(/\e\[[0-9;]*m/, "")
end

describe "bug hunt round 1" do
  it "concurrent first runs all create DOMA_HOME instead of one losing the mkdir race" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    with_r1_dir do |_, home|
      done = Channel(Process::Status).new
      16.times { spawn { done.send(r1(["tags"], home)[:status]) } }
      16.times.map { done.receive }.count(&.success?).should eq(16)
      Dir.exists?(home).should be_true
    end
  end

  it "concurrent `config set` calls don't trip over a shared temp file" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    with_r1_dir do |_, home|
      done = Channel(Process::Status).new
      12.times { |i| spawn { done.send(r1(["config", "set", i.even? ? "selector" : "auto_tag.git", i.even? ? "first" : "true"], home)[:status]) } }
      12.times.map { done.receive }.count(&.success?).should eq(12)
      Dir.children(home).select(&.ends_with?(".tmp")).should be_empty
    end
  end

  it "info and move report an unreadable parent cleanly, not as an internal error" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    pending! "root ignores directory permissions" if LibC.getuid == 0
    with_r1_dir do |dir, home|
      target = File.join(dir, "locked", "proj")
      other = File.join(dir, "other")
      FileUtils.mkdir_p(target)
      FileUtils.mkdir_p(other)
      r1(["add", target, other], home)[:status].success?.should be_true
      File.chmod(File.join(dir, "locked"), 0o000)

      info = r1(["info", target], home)
      info[:err].should_not contain("internal error")
      info[:status].success?.should be_true
      info[:out].should contain("exists      yes")

      move = r1(["move", other, File.join(dir, "locked", "new")], home)
      move[:err].should_not contain("internal error")
      move[:err].should contain("cannot access")
      move[:status].exit_code.should eq(2)

      export = r1(["export", "-o", File.join(dir, "locked", "out.json")], home)
      export[:err].should_not contain("internal error")
      export[:status].exit_code.should eq(2)
    end
  end

  it "export -o /dev/stdout streams the snapshot instead of failing on a temp file" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    with_r1_dir do |dir, home|
      r1(["add", dir, "-t", "x"], home)
      r = r1(["export", "-o", "/dev/stdout"], home)
      r[:status].success?.should be_true
      # Nothing but the snapshot: a success line would corrupt the stream.
      JSON.parse(r[:out])["entries"].as_a.size.should eq(1)
      r1(["export", "-o", "/dev/null"], home)[:status].success?.should be_true
    end
  end

  it "stats keeps the count column aligned for long tags when colored" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    with_r1_dir do |dir, home|
      r1(["add", dir, "-t", "work", "-t", "a-rather-long-tag-name"], home)
      rows = strip_ansi(r1(["--color", "stats"], home)[:out]).lines.select(&.starts_with?("  #"))
      rows.size.should eq(2)
      rows.map(&.index!(" 1  ")).uniq!.size.should eq(1)
    end
  end

  it "trash list aligns the TAGS column for wide (Hangul) paths" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    with_r1_dir do |dir, home|
      wide = File.join(dir, "한글디렉터리-한글디렉터리-한글디렉터리")
      plain = File.join(dir, "plain")
      FileUtils.mkdir_p(wide)
      FileUtils.mkdir_p(plain)
      r1(["add", wide, plain, "-t", "zz"], home)
      r1(["rm", wide, plain], home)[:status].success?.should be_true
      rows = r1(["trash", "list"], home)[:out].lines[1..]
      rows.size.should eq(2)
      rows.map { |l| Doma::TUI::Text.display_width(l.rchop("zz")) }.uniq!.size.should eq(1)
    end
  end

  it "tags / stats / doctor reject stray positionals instead of ignoring them" do
    pending! "binary not built" unless File.exists?(R1_BIN)
    with_r1_dir do |_, home|
      %w[tags stats doctor].each do |cmd|
        r = r1([cmd, "bogus"], home)
        r[:status].exit_code.should eq(2)
        r[:err].should contain("#{cmd} takes no positional arguments: bogus")
      end
    end
  end

  it "config parse errors name the expected shape, not Crystal type names" do
    Doma::Settings.current = nil
    {
      "- a\n"                    => "expected mapping, got sequence",
      "auto_tag: 5\n"            => "expected basename / git / project, each true or false",
      "auto_tag:\n  git: nope\n" => "expected basename / git / project, each true or false",
      "db_path: [1]\n"           => "expected a string",
    }.each do |yaml, expected|
      path = File.tempname("doma-r1-cfg", ".yml")
      File.write(path, yaml)
      begin
        ex = expect_raises(Doma::ConfigError) { Doma::Settings.load(path) }
        ex.message.to_s.should contain(expected)
        ex.message.to_s.should_not contain("Doma::")
      ensure
        File.delete(path)
      end
    end
  end

  it "tag expirations come back in name order so exports stay diffable" do
    with_temp_db do |db|
      dir = File.tempname("doma-r1-exp")
      FileUtils.mkdir_p(dir)
      begin
        later = Time.utc.to_unix + 3600
        id = db.add(dir, ["zeta"], expires_at: later)
        db.add(dir, ["alpha"], expires_at: later + 1)
        db.add(dir, ["mid"], expires_at: later)
        db.tag_expirations(id).keys.should eq(%w[alpha mid zeta])
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
