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
      info.to_tags.should eq(["git"])
    end
  end

  it "parses HTTPS GitHub remotes" do
    with_fake_repo("https://github.com/hahwul/doma.git") do |dir|
      info = Doma::GitDetector.detect(dir)
      info.host.should eq("github")
      info.owner.should eq("hahwul")
      info.repo.should eq("doma")
      info.to_tags.should eq(["git", "github", "doma"])
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
      info.to_tags.should eq(["git"])
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
end
