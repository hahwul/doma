require "./spec_helper"

private def with_fake_repo(remote_url : String?, &)
  dir = File.tempname("doma-git")
  FileUtils.mkdir_p(File.join(dir, ".git"))
  if remote_url
    File.write(
      File.join(dir, ".git", "config"),
      <<-CFG
        [core]
          repositoryformatversion = 0
        [remote "origin"]
          url = #{remote_url}
        CFG
    )
  end
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Doma::GitDetector do
  it "returns git=false for a non-repo directory" do
    dir = File.tempname("doma-nogit")
    FileUtils.mkdir_p(dir)
    begin
      info = Doma::GitDetector.detect(dir)
      info.git.should be_false
      info.to_tags.should be_empty
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "marks a repo without a remote as git=true with no host tag" do
    with_fake_repo(nil) do |dir|
      info = Doma::GitDetector.detect(dir)
      info.git.should be_true
      info.host.should be_nil
      # No `git` tag — every git repo would carry it (zero selectivity).
      info.to_tags.should be_empty
    end
  end

  it "parses HTTPS GitHub remotes" do
    with_fake_repo("https://github.com/hahwul/doma.git") do |dir|
      info = Doma::GitDetector.detect(dir)
      info.host.should eq("github")
      info.owner.should eq("hahwul")
      info.repo.should eq("doma")
      info.to_tags.should eq(["github", "doma"])
    end
  end

  it "returns an empty result when the git config is unreadable (never raises)" do
    pending! "permission bits don't bind root" if LibC.getuid == 0
    with_fake_repo("https://github.com/hahwul/doma.git") do |dir|
      cfg = File.join(dir, ".git", "config")
      File.chmod(cfg, File::Permissions.new(0))
      begin
        info = Doma::GitDetector.detect(dir)
        info.to_tags.should be_empty
      ensure
        File.chmod(cfg, File::Permissions.new(0o600))
      end
    end
  end

  it "parses SCP-style SSH remotes" do
    with_fake_repo("git@github.com:hahwul/doma.git") do |dir|
      info = Doma::GitDetector.detect(dir)
      info.host.should eq("github")
      info.repo.should eq("doma")
    end
  end

  it "parses ssh:// remotes" do
    with_fake_repo("ssh://git@gitlab.com/group/sub/repo.git") do |dir|
      info = Doma::GitDetector.detect(dir)
      info.host.should eq("gitlab")
      info.repo.should eq("repo")
    end
  end

  it "passes self-hosted hosts through unchanged" do
    with_fake_repo("git@git.example.com:team/widget.git") do |dir|
      info = Doma::GitDetector.detect(dir)
      info.host.should eq("git.example.com")
      info.repo.should eq("widget")
    end
  end

  it "walks up to find the git root" do
    with_fake_repo("https://github.com/x/y.git") do |dir|
      sub = File.join(dir, "deep", "sub", "tree")
      FileUtils.mkdir_p(sub)
      info = Doma::GitDetector.detect(sub)
      info.git.should be_true
      info.repo.should eq("y")
    end
  end

  it "treats an empty .git/config as 'git but no remote'" do
    dir = File.tempname("doma-git-empty")
    FileUtils.mkdir_p(File.join(dir, ".git"))
    File.write(File.join(dir, ".git", "config"), "")
    begin
      info = Doma::GitDetector.detect(dir)
      info.git.should be_true
      info.host.should be_nil
      info.repo.should be_nil
      info.to_tags.should be_empty
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "ignores a remote section that has no url= line" do
    dir = File.tempname("doma-git-no-url")
    FileUtils.mkdir_p(File.join(dir, ".git"))
    File.write(
      File.join(dir, ".git", "config"),
      <<-CFG
        [core]
          repositoryformatversion = 0
        [remote "origin"]
          fetch = +refs/heads/*:refs/remotes/origin/*
        CFG
    )
    begin
      info = Doma::GitDetector.detect(dir)
      info.git.should be_true
      info.host.should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "leaves host/repo nil for a remote URL it can't parse" do
    with_fake_repo("garbage-url-with-no-recognizable-shape") do |dir|
      info = Doma::GitDetector.detect(dir)
      info.git.should be_true
      info.host.should be_nil
      info.repo.should be_nil
    end
  end

  it "returns the EMPTY result for a path that doesn't exist" do
    info = Doma::GitDetector.detect("/no/such/path/anywhere")
    info.git.should be_false
    info.to_tags.should be_empty
  end

  it "to_tags is stable across calls (no dup if host == 'git')" do
    with_fake_repo("https://github.com/me/repo.git") do |dir|
      info = Doma::GitDetector.detect(dir)
      tags = info.to_tags
      tags.should eq(tags.uniq!)
    end
  end

  it "resolves the remote from a worktree's common dir (.git file + commondir)" do
    # A linked worktree's `.git` is a *file* pointing at a gitdir that
    # holds no `config` of its own — the shared config lives in the
    # common dir (`commondir`). Before the fix, `read_origin_url` looked
    # only inside the worktree gitdir and silently produced no git tags.
    root = File.tempname("doma-git-wt")
    begin
      # Primary repo: real .git/ with the remote config.
      main_git = File.join(root, "main", ".git")
      FileUtils.mkdir_p(main_git)
      File.write(
        File.join(main_git, "config"),
        <<-CFG
          [remote "origin"]
            url = https://github.com/hahwul/doma.git
          CFG
      )

      # Linked worktree gitdir under the primary repo, with a `commondir`
      # pointing back up to the shared .git (../..), mirroring git's layout.
      wt_gitdir = File.join(main_git, "worktrees", "feature")
      FileUtils.mkdir_p(wt_gitdir)
      File.write(File.join(wt_gitdir, "commondir"), "../..\n")

      # The worktree checkout: a `.git` *file* pointing at the gitdir.
      worktree = File.join(root, "feature")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(worktree, ".git"), "gitdir: #{wt_gitdir}\n")

      info = Doma::GitDetector.detect(worktree)
      info.git.should be_true
      info.host.should eq("github")
      info.repo.should eq("doma")
      info.to_tags.should eq(["github", "doma"])
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
