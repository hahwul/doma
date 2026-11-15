require "./spec_helper"
require "json"

# Regressions for the add/mark/path-validation fixes (group add-path).

private FIX_BIN = File.expand_path("../bin/doma", __DIR__)

private def doma(home : String, args : Array(String), cwd : String? = nil)
  env = {
    "DOMA_HOME"   => home,
    "DOMA_DB"     => File.join(home, "doma.db"),
    "DOMA_CONFIG" => File.join(home, "config.yml"),
    "DOMA_NO_TUI" => "1",
  }
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(FIX_BIN, args, env: env, output: stdout, error: stderr, chdir: cwd)
  {out: stdout.to_s, err: stderr.to_s, status: status}
end

private def with_ws(&)
  root = File.tempname("doma-fix-add-path")
  home = File.join(root, "home")
  ws = File.join(root, "ws")
  FileUtils.mkdir_p([home, ws])
  begin
    yield home, File.realpath(ws)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "fix add-path" do
  it "mark/--ttl leaves derived tags permanent (#0)" do
    with_ws do |home, ws|
      proj = File.join(ws, "proj")
      Dir.mkdir(proj)
      File.touch(File.join(proj, "shard.yml"))
      doma(home, ["config", "set", "auto_tag.project", "true"])
      doma(home, ["config", "set", "auto_tag.basename", "true"])
      doma(home, ["add", proj, "-t", "work"])[:status].success?.should be_true
      doma(home, ["mark", "-p", proj, "review"])[:status].success?.should be_true

      db = Doma::Database.open(File.join(home, "doma.db"))
      begin
        entry = (db.find_entry(proj) || raise "entry missing")
        exp = db.tag_expirations(entry.id, include_past: true)
        exp.keys.should eq(["review"])
        entry.tags.sort.should eq(%w[crystal proj review work])
      ensure
        db.close
      end
    end
  end

  it "mark refreshes an expired derived tag to permanent and labels the TTL on user tags only" do
    with_ws do |home, ws|
      proj = File.join(ws, "proj")
      Dir.mkdir(proj)
      File.touch(File.join(proj, "shard.yml"))
      flags = ["--project-tag", "--auto-tag", "--no-git-tag"]
      doma(home, ["add", proj, "-t", "work"] + flags)[:status].success?.should be_true
      db = Doma::Database.open(File.join(home, "doma.db"))
      begin
        id = (db.find_entry(proj) || raise "entry missing").id
        db.transaction do |cnn|
          cnn.exec("UPDATE directory_tags SET expires_at = 1000 WHERE directory_id = ? " \
                   "AND tag_id = (SELECT id FROM tags WHERE name = 'crystal')", id)
        end
      ensure
        db.close
      end

      r = doma(home, ["add", proj, "-t", "review", "--ttl", "1d"] + flags)
      r[:out].should match(/tags: review \(expires [^)]+\), proj, crystal/)
      row = JSON.parse(doma(home, ["add", proj, "-t", "review", "--ttl", "1d", "--json"] + flags)[:out]).as_a.first
      row["derived_tags"].as_a.map(&.as_s).sort!.should eq(%w[crystal proj])

      db = Doma::Database.open(File.join(home, "doma.db"))
      begin
        db.tag_expirations(id, include_past: true).keys.should eq(["review"])
      ensure
        db.close
      end
    end
  end

  it "new derived tags under --ttl are written permanent (#0)" do
    with_ws do |home, ws|
      proj = File.join(ws, "fresh")
      Dir.mkdir(proj)
      doma(home, ["add", proj, "-t", "bm", "--tmp", "--auto-tag"])[:status].success?.should be_true
      db = Doma::Database.open(File.join(home, "doma.db"))
      begin
        entry = (db.find_entry(proj) || raise "entry missing")
        db.tag_expirations(entry.id, include_past: true).keys.should eq(["bm"])
        entry.tags.sort.should eq(%w[bm fresh])
      ensure
        db.close
      end
    end
  end

  it "path! uses the path as given, spaces included (#2/#36)" do
    with_ws do |home, ws|
      Dir.mkdir(File.join(ws, "proj "))
      Dir.mkdir(File.join(ws, "proj"))
      Dir.mkdir(File.join(ws, " lead"))
      Doma::Validator.path!(File.join(ws, "proj ")).should eq(File.join(ws, "proj "))
      Doma::Validator.path!(File.join(ws, " lead")).should eq(File.join(ws, " lead"))
      expect_raises(Doma::ValidationError, "path is empty") { Doma::Validator.path!("   ") }
      r = doma(home, ["add", "proj ", "-t", "trail"], ws)
      r[:status].success?.should be_true
      doma(home, ["list", "--paths"])[:out].lines.should eq([File.join(ws, "proj ")])
    end
  end

  it "mark forwards --json (#3)" do
    with_ws do |home, ws|
      r = doma(home, ["mark", "spike", "--json"], ws)
      r[:status].success?.should be_true
      rows = JSON.parse(r[:out]).as_a
      rows.first["path"].as_s.should eq(ws)
      rows.first["tags"].as_a.map(&.as_s).should contain("spike")
    end
  end

  it "rejects an empty path instead of resolving it to the cwd (#40/#63)" do
    expect_raises(Doma::ValidationError, "path is empty") { Doma::Validator.canonicalize("") }
    with_ws do |home, ws|
      doma(home, ["add", "-t", "bb", "--no-auto-tag"], ws)[:status].success?.should be_true
      r = doma(home, ["rm", ""], ws)
      r[:status].exit_code.should eq(2)
      r[:err].should contain("path is empty")
      doma(home, ["rm", "", "-t", "bb"], ws)[:status].exit_code.should eq(2)
      doma(home, ["list", "--paths"])[:out].lines.should eq([ws])
    end
  end

  it "dry-run reports unchanged like the real run (#42)" do
    with_ws do |home, ws|
      flags = ["--no-auto-tag", "--no-git-tag", "--no-project-tag"]
      doma(home, ["add", ws, "-t", "x"] + flags)
      row = JSON.parse(doma(home, ["add", ws, "-t", "x", "--dry-run", "--json"] + flags)[:out]).as_a.first
      row["unchanged"].as_bool.should be_true
      doma(home, ["add", ws, "-t", "x", "--dry-run"] + flags)[:out].should contain("[dry-run] no change")
      row = JSON.parse(doma(home, ["add", ws, "-t", "y", "--dry-run", "--json"] + flags)[:out]).as_a.first
      row["unchanged"].as_bool.should be_false
    end
  end

  {% unless flag?(:win32) %}
    it "an EACCES path is a per-path ValidationError, not an internal error (#64)" do
      with_ws do |home, ws|
        locked = File.join(ws, "locked")
        child = File.join(locked, "child")
        b1 = File.join(ws, "b1")
        b2 = File.join(ws, "b2")
        FileUtils.mkdir_p([child, b1, b2])
        File.chmod(locked, 0o000)
        begin
          r = doma(home, ["add", b1, child, b2, "-t", "q"])
          r[:status].exit_code.should eq(2)
          r[:err].should_not contain("internal error")
          doma(home, ["list", "--paths"])[:out].lines.sort.should eq([b1, b2])
        ensure
          File.chmod(locked, 0o755)
        end
      end
    end

    it "an unreadable marker dir skips project tags instead of crashing (#65)" do
      with_ws do |home, ws|
        norx = File.join(ws, "norx")
        Dir.mkdir(norx)
        File.chmod(norx, 0o600)
        begin
          Doma::Project.types(norx).should eq([] of String)
          r = doma(home, ["add", "--project-tag", norx])
          r[:status].success?.should be_true
        ensure
          File.chmod(norx, 0o755)
        end
      end
    end
  {% end %}

  it "non-ASCII digits get the plain invalid-duration message (#66)" do
    expect_raises(Doma::ValidationError, "invalid duration") { Doma::Duration.parse_seconds!("５m") }
    expect_raises(Doma::ValidationError, "invalid duration") { Doma::Duration.parse_seconds!("٣d") }
  end
end
