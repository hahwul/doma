require "./spec_helper"

ROOT = File.expand_path("..", __DIR__)

describe "tooling fixes" do
  it "[#38] bench/bench.cr still compiles against the current Database API" do
    err = IO::Memory.new
    status = Process.run("crystal", ["build", "--no-codegen", "bench/bench.cr"],
      chdir: ROOT, output: Process::Redirect::Close, error: err)
    status.success?.should be_true, err.to_s
  end

  it "[#39] version_update syncs drifted files even when the target equals shard.yml" do
    dir = File.tempname("doma-vu")
    FileUtils.mkdir_p(File.join(dir, "src"))
    FileUtils.mkdir_p(File.join(dir, "snap"))
    FileUtils.mkdir_p(File.join(dir, "aur"))
    File.write(File.join(dir, "shard.yml"), "name: doma\nversion: 0.6.0\n")
    File.write(File.join(dir, "src/doma.cr"), "VERSION = \"0.6.0\"\n")
    File.write(File.join(dir, "snap/snapcraft.yaml"), "name: doma\nversion: 0.6.0\n")
    File.write(File.join(dir, "aur/PKGBUILD"), "pkgver=0.5.0\npkgrel=2\n")
    begin
      log = IO::Memory.new
      status = Process.run("crystal", ["run", File.join(ROOT, "scripts/version_update.cr")],
        chdir: dir, input: IO::Memory.new("0.6.0\n"), output: log, error: log)
      status.success?.should be_true, log.to_s
      File.read(File.join(dir, "aur/PKGBUILD")).should contain("pkgver=0.6.0")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "[#67] shard.lock no longer pins the ameba commit that fails on Crystal 1.22" do
    File.read(File.join(ROOT, "shard.lock")).should_not contain("77bf37bb")
  end

  it "[#68] `just test` builds bin/doma before running the specs" do
    recipe = File.read(File.join(ROOT, "justfile"))[/(?m)^test:\n((?:    .*\n)+)/, 1]
    recipe.should contain("shards build")
    recipe.index!("shards build").should be < recipe.index!("crystal spec")
  end

  it "[#83] spec_helper drops DOMA_DB / DOMA_CONFIG / DOMA_YES / DOMA_CD_FILE" do
    # Spawned bin/doma inherits ENV; these would override the per-spec home.
    %w[DOMA_DB DOMA_CONFIG DOMA_YES DOMA_CD_FILE].each { |k| ENV[k]?.should be_nil }
  end
end
