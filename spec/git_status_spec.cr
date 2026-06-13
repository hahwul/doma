require "./spec_helper"

# The porcelain v2 + --branch shapes the parser has to handle. Sample
# strings keep the bulk of the suite hermetic — no git process, no temp
# repo — so the parsing logic is exercised directly. A single guarded
# integration test below confirms the spawn path against a real repo.

private CLEAN = <<-OUT
  # branch.oid 1111111111111111111111111111111111111111
  # branch.head main
  # branch.upstream origin/main
  # branch.ab +0 -0
  OUT

# One staged-only (M.), one unstaged-only (.M), one both (MM), one
# untracked (?), one conflict (u UU). modified=3, staged=2, unstaged=2,
# untracked=1, conflicts=1, dirty=3+1+1=5.
private DIRTY = <<-OUT
  # branch.oid 2222222222222222222222222222222222222222
  # branch.head feat/x
  # branch.upstream origin/feat/x
  # branch.ab +2 -3
  1 M. N... 100644 100644 100644 aaa aaa staged.txt
  1 .M N... 100644 100644 100644 bbb bbb unstaged.txt
  1 MM N... 100644 100644 100644 ccc ccc both.txt
  u UU N... 100644 100644 100644 100644 ddd eee fff conflict.txt
  ? untracked.txt
  OUT

private DETACHED = <<-OUT
  # branch.oid 3333333333333333333333333333333333333333
  # branch.head (detached)
  OUT

private NO_UPSTREAM = <<-OUT
  # branch.oid 4444444444444444444444444444444444444444
  # branch.head solo
  OUT

describe Doma::GitStatus do
  describe ".parse" do
    it "reads branch + in-sync upstream for a clean tree" do
      s = Doma::GitStatus.parse(CLEAN)
      s.git.should be_true
      s.branch.should eq("main")
      s.upstream.should eq("origin/main")
      s.detached.should be_false
      s.ahead.should eq(0)
      s.behind.should eq(0)
      s.dirty.should eq(0)
      s.clean?.should be_true
      s.diverged?.should be_false
    end

    it "counts staged / unstaged / untracked / conflicts and ahead-behind" do
      s = Doma::GitStatus.parse(DIRTY)
      s.branch.should eq("feat/x")
      s.ahead.should eq(2)
      s.behind.should eq(3)
      s.modified.should eq(3)
      s.staged.should eq(2)
      s.unstaged.should eq(2)
      s.untracked.should eq(1)
      s.conflicts.should eq(1)
      # modified + untracked + conflicts — no double counting of MM.
      s.dirty.should eq(5)
      s.clean?.should be_false
      s.diverged?.should be_true
    end

    it "flags a detached HEAD with no branch name" do
      s = Doma::GitStatus.parse(DETACHED)
      s.detached.should be_true
      s.branch.should be_nil
      s.upstream.should be_nil
    end

    it "leaves upstream nil and diverged? false without an upstream line" do
      s = Doma::GitStatus.parse(NO_UPSTREAM)
      s.branch.should eq("solo")
      s.upstream.should be_nil
      s.diverged?.should be_false
    end

    it "treats empty output as a git repo with nothing to report" do
      s = Doma::GitStatus.parse("")
      s.git.should be_true
      s.branch.should be_nil
      s.clean?.should be_true
    end
  end

  describe ".probe" do
    it "returns git=false for a directory that isn't a repo" do
      dir = File.tempname("doma-nogit-probe")
      FileUtils.mkdir_p(dir)
      begin
        s = Doma::GitStatus.probe(dir)
        s.git.should be_false
        s.clean?.should be_false # not a repo → not "clean"
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "reports a real repo's branch and dirty state" do
      pending! "git not on PATH" unless Doma::GitStatus.available?
      dir = File.tempname("doma-realrepo")
      FileUtils.mkdir_p(dir)
      env = {
        "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t",
        "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t",
      }
      begin
        run = ->(args : Array(String)) do
          Process.run("git", args: ["-C", dir] + args, env: env,
            output: Process::Redirect::Close, error: Process::Redirect::Close)
        end
        run.call(["init", "-q"])
        run.call(["commit", "-q", "--allow-empty", "-m", "init"])

        clean = Doma::GitStatus.probe(dir)
        clean.git.should be_true
        clean.clean?.should be_true

        File.write(File.join(dir, "new.txt"), "x")
        dirty = Doma::GitStatus.probe(dir)
        dirty.git.should be_true
        dirty.clean?.should be_false
        dirty.untracked.should eq(1)
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
