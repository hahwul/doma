require "./spec_helper"
require "json"

# Regression coverage for the rm/info fix group.

private FIX_BIN = File.expand_path("../bin/doma", __DIR__)

private def doma(args : Array(String), home : String, *, chdir : String? = nil)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(FIX_BIN, args, env: {"DOMA_HOME" => home}, chdir: chdir, output: out_io, error: err_io)
  {out: out_io.to_s, err: err_io.to_s, status: status}
end

private def with_fix_home(&)
  home = File.realpath(File.tempname("doma-fix-rm-info").tap { |d| FileUtils.mkdir_p(d) })
  begin
    yield home
  ensure
    FileUtils.rm_rf(home)
  end
end

private def sql(home : String, stmt : String)
  DB.open("sqlite3://#{File.join(home, "doma.db")}") { |d| d.exec(stmt) }
end

private def short_id_of(home : String, path : String) : String
  JSON.parse(doma(["list", "--json"], home)[:out]).as_a.find! { |e| e["path"].as_s == path }["short_id"].as_s
end

private def listed_paths(home : String) : Array(String)
  doma(["list", "--paths"], home)[:out].lines
end

describe "rm/info fixes" do
  it "#62: rm <id> removes the stored row even after its path became a symlink" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      app = File.join(home, "app")
      v2 = File.join(home, "app-v2")
      FileUtils.mkdir_p([app, v2])
      doma(["add", app, "-t", "old"], home)
      doma(["add", v2, "-t", "new"], home)
      id = short_id_of(home, app)
      FileUtils.rm_rf(app)
      File.symlink(v2, app)

      r = doma(["rm", id], home)
      r[:status].exit_code.should eq(0)
      r[:out].should contain("trashed #{app} ")
      listed_paths(home).should eq([v2])
    end
  end

  it "#62: a stored path whose symlink target is unregistered can still be removed" do
    with_temp_db do |db|
      base = File.realpath(ENV["DOMA_HOME"])
      code = File.join(base, "code")
      FileUtils.mkdir_p(code)
      db.add(code, [] of String)
      FileUtils.mv(code, File.join(base, "ext"))
      File.symlink(File.join(base, "ext"), code)

      db.row_path(code).should eq(code)
      db.remove_path(code).should be_true
      db.directories.should be_empty
    end
  end

  it "#1: rm <hexname> of a vanished registered dir removes that row, not a short_id match" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      proj = File.join(home, "proj")
      FileUtils.mkdir_p(proj)
      doma(["add", proj], home)
      name = short_id_of(home, proj)[0, 4]
      hex = File.join(home, name)
      FileUtils.mkdir_p(hex)
      doma(["add", hex], home)
      Dir.delete(hex)

      r = doma(["rm", name], home, chdir: home)
      r[:status].exit_code.should eq(0)
      listed_paths(home).should eq([proj])
    end
  end

  it "#69: a bad item mid-batch doesn't skip the rest, and exits 2" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      e, f, g = %w(e f g).map { |n| File.join(home, n).tap { |d| FileUtils.mkdir_p(d) } }
      doma(["add", e, f, g], home)
      sql(home, "UPDATE directories SET short_id = 'abcd111' WHERE basename = 'e'")
      sql(home, "UPDATE directories SET short_id = 'abcd222' WHERE basename = 'f'")

      r = doma(["rm", g, "abcd", e], home)
      r[:status].exit_code.should eq(2)
      r[:err].should contain("ambiguous")
      listed_paths(home).should eq([f])
    end
  end

  it "#70: rm -t reports only the tags actually removed" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      doma(["add", home, "-t", "keep", "-t", "z"], home)
      r = doma(["rm", home, "-t", "keep", "-t", "nothere", "-t", "z"], home)
      r[:status].exit_code.should eq(0)
      r[:out].should contain("(keep, z; not on path: nothere)")
    end
  end

  it "#84: rm -t drops a stored legacy tag today's rules reject" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      doma(["add", home, "-t", "keep"], home)
      sql(home, "INSERT INTO tags(name, created_at) VALUES('work/', 0)")
      sql(home, "INSERT INTO directory_tags(directory_id, tag_id) SELECT d.id, t.id FROM directories d, tags t WHERE t.name = 'work/'")

      doma(["rm", home, "-t", "work/"], home)[:status].exit_code.should eq(0)
      doma(["list", "-t", "work/", "--paths"], home)[:out].should be_empty
      # A name that's neither stored nor valid still fails fast.
      doma(["rm", home, "-t", "bad//x"], home)[:status].exit_code.should eq(2)
    end
  end

  it "#5: info <name> for an existing unregistered ./name says not registered" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      FileUtils.mkdir_p([File.join(home, "ace"), File.join(home, "sp ace")])
      doma(["add", File.join(home, "sp ace")], home)

      r = doma(["info", "ace"], home, chdir: home)
      r[:status].exit_code.should eq(3)
      r[:err].should contain("not registered: #{File.join(home, "ace")}")

      # Hex-shaped name: still a directory, not a short_id miss.
      FileUtils.mkdir_p([File.join(home, "cafe"), File.join(home, "q", "cafebar")])
      doma(["add", File.join(home, "q", "cafebar")], home)
      r = doma(["info", "cafe"], home, chdir: home)
      r[:status].exit_code.should eq(3)
      r[:err].should contain("not registered: #{File.join(home, "cafe")}")
      r[:err].should contain("doma add cafe")
    end
  end

  it "#62: move names the stored source row even after it became a symlink" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      app = File.join(home, "app")
      v2 = File.join(home, "app-v2")
      dest = File.join(home, "new")
      FileUtils.mkdir_p([app, v2, dest])
      doma(["add", app, "-t", "old"], home)
      doma(["add", v2, "-t", "new"], home)
      FileUtils.rm_rf(app)
      File.symlink(v2, app)

      doma(["move", app, dest], home)[:out].should contain("moved #{app} -> #{dest}")
      listed_paths(home).sort.should eq([v2, dest].sort)

      doma(["move", dest, v2], home)[:out].should contain("merged #{dest} into existing #{v2}")
      listed_paths(home).should eq([v2])
    end
  end

  it "#45: the `doma add` hint is shell-quoted" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      FileUtils.mkdir_p(File.join(home, "e f"))
      doma(["info", "./e f"], home, chdir: home)[:err].should contain("doma add './e f'")
      doma(["rm", "./e f"], home, chdir: home)[:err].should contain("doma add './e f'")
      doma(["info", "./it's"], home, chdir: home)[:err].should contain(%q(doma add './it'\''s'))
    end
  end

  it "#87: info rejects more than one argument" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      doma(["add", home], home)
      r = doma(["info", home, "/nope"], home)
      r[:status].exit_code.should eq(2)
      r[:err].should contain("info takes one path or short_id")
      JSON.parse(doma(["info", "--json", home, "/nope"], home)[:out])["found"].as_bool.should be_false
    end
  end

  it "#4: rm --hard refusal names the real condition" do
    pending! "binary not built" unless File.exists?(FIX_BIN)
    with_fix_home do |home|
      doma(["add", home], home)
      r = doma(["rm", "--hard", home], home)
      r[:status].exit_code.should eq(1)
      r[:err].should contain("not attached to a terminal (stdin/stdout)")
    end
  end
end
