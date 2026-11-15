require "./spec_helper"

private FIX_IMPORT_BIN = File.expand_path("../bin/doma", __DIR__)

private def fix_import_run(args : Array(String), home : String, input : Process::Stdio = Process::Redirect::Close)
  stdout = IO::Memory.new
  err = IO::Memory.new
  env = {"DOMA_HOME" => home, "DOMA_NO_TUI" => "1", "DOMA_DB" => File.join(home, "doma.db"), "DOMA_CONFIG" => File.join(home, "config.toml")}
  status = Process.run(FIX_IMPORT_BIN, args, env: env, input: input, output: stdout, error: err)
  {out: stdout.to_s, err: err.to_s, status: status}
end

private def with_snapshot(json : String, &)
  path = File.tempname("doma-fix-import") + ".json"
  File.write(path, json)
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

private def with_cli_home(&)
  home = File.tempname("doma-fix-import-home")
  FileUtils.mkdir_p(home)
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

describe "import fixes" do
  # Bug 24
  it "rejects an extra positional file instead of silently dropping it" do
    with_cli_home do |home|
      with_snapshot(%({"version":2,"entries":[]})) do |snap|
        r = fix_import_run(["import", snap, "extra.json"], home)
        r[:status].success?.should be_false
        r[:err].should contain("unexpected argument 'extra.json'")
      end
    end
  end

  # Bug 75
  it "reads the snapshot from /dev/stdin" do
    with_cli_home do |home|
      with_snapshot(%({"version":2,"entries":[{"path":"/fix/stdin","tags":["s"]}]})) do |snap|
        File.open(snap) do |f|
          r = fix_import_run(["import", "/dev/stdin", "--dry-run"], home, input: f)
          r[:status].success?.should be_true
          r[:out].should contain("1 imported")
        end
      end
    end
  end

  # Bug 54
  it "merge keeps the longer lifetime of a live tag" do
    with_temp_db do |db|
      db.add("/fix/keep", ["keep", "timed"], validate_path: false)
      future = Time.utc.to_unix + 3600
      db.add("/fix/keep", ["timed"], validate_path: false, expires_at: future)
      later = future + 3600
      json = %({"version":2,"entries":[{"path":"/fix/keep","tags":["keep","timed"],) +
             %("expirations":{"keep":1000,"timed":#{later}}}]})
      with_snapshot(json) do |snap|
        Doma::Importer.from_file(db, snap).updated.should eq(1)
      end
      id = db.directories(include_expired: true).find!(&.path.==("/fix/keep")).id
      exp = db.tag_expirations(id, include_past: true)
      exp.has_key?("keep").should be_false # still permanent
      exp["timed"].should eq(later)
    end
  end

  # Bug 56
  it "treats an unreadable directory as present instead of crashing" do
    dir = File.tempname("doma-fix-locked")
    Dir.mkdir(dir)
    File.chmod(dir, 0o000)
    begin
      Doma::Importer.absent?(dir).should be_false
    ensure
      File.chmod(dir, 0o755)
      Dir.delete(dir)
    end
  end

  # Bug 81
  it "keeps a directory whose tag has a legacy empty segment" do
    with_temp_db do |db|
      json = %({"version":2,"entries":[{"path":"/fix/legacy","tags":["keep","work/","a//b"]}]})
      with_snapshot(json) do |snap|
        result = Doma::Importer.from_file(db, snap)
        result.imported.should eq(1)
        result.skipped.should eq(0)
      end
      db.directories.find!(&.path.==("/fix/legacy")).tags.sort.should eq(["a/b", "keep", "work"])
    end
  end
end
