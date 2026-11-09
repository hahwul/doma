require "./spec_helper"

private def touch(path : String)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "")
end

describe Doma::Project do
  it ".types maps marker files to tags, several per directory" do
    dir = File.tempname("doma-proj")
    begin
      touch(File.join(dir, "shard.yml"))
      touch(File.join(dir, "package.json"))
      touch(File.join(dir, "setup.py"))
      touch(File.join(dir, "requirements.txt"))
      Doma::Project.types(dir).should eq(%w[crystal node python])
      Doma::Project.types(File.join(dir, "missing")).should eq([] of String)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it ".repos finds git repos as leaves, skipping hidden, vendor, symlinked, and too-deep non-repo dirs" do
    root = File.tempname("doma-scan")
    begin
      FileUtils.mkdir_p(File.join(root, "a", ".git"))
      FileUtils.mkdir_p(File.join(root, "a", "nested", ".git")) # inside a repo: not listed
      touch(File.join(root, "b", "c", ".git"))                  # worktree-style .git file
      FileUtils.mkdir_p(File.join(root, "node_modules", "x", ".git"))
      FileUtils.mkdir_p(File.join(root, ".hidden", "y", ".git"))
      FileUtils.mkdir_p(File.join(root, "d1", "d2", "d3", "d4", "d5", ".git")) # depth 5
      FileUtils.mkdir_p(File.join(root, "d1", "d2", "d3", "ok", ".git"))       # depth 4
      FileUtils.mkdir_p(File.join(root, ".dotfiles", ".git"))                  # hidden, but a repo
      FileUtils.mkdir_p(File.join(root, "vendor", ".git"))                     # SKIP name, but a repo
      File.symlink(File.join(root, "a"), File.join(root, "link"))
      Doma::Project.repos(root).should eq([
        File.join(root, ".dotfiles"),
        File.join(root, "a"),
        File.join(root, "b", "c"),
        File.join(root, "d1", "d2", "d3", "ok"),
        File.join(root, "vendor"),
      ])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it ".repos raises for an unreadable root instead of reporting no repos" do
    expect_raises(File::Error) { Doma::Project.repos(File.tempname("doma-scan-missing")) }
  end

  it ".repos returns the root itself when it is a repo" do
    root = File.tempname("doma-scan-root")
    begin
      FileUtils.mkdir_p(File.join(root, ".git"))
      FileUtils.mkdir_p(File.join(root, "sub", ".git"))
      Doma::Project.repos(root).should eq([root])
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
