require "./spec_helper"

describe Doma::Installer do
  describe ".detect_shell" do
    it "returns the basename when $SHELL is supported" do
      prev = ENV["SHELL"]?
      begin
        ENV["SHELL"] = "/bin/zsh"
        Doma::Installer.detect_shell.should eq("zsh")
        ENV["SHELL"] = "/usr/local/bin/bash"
        Doma::Installer.detect_shell.should eq("bash")
        ENV["SHELL"] = "/opt/homebrew/bin/fish"
        Doma::Installer.detect_shell.should eq("fish")
      ensure
        prev ? (ENV["SHELL"] = prev) : ENV.delete("SHELL")
      end
    end

    it "returns nil for unsupported shells" do
      prev = ENV["SHELL"]?
      begin
        ENV["SHELL"] = "/usr/bin/xonsh"
        Doma::Installer.detect_shell.should be_nil
        ENV["SHELL"] = "/usr/bin/tcsh"
        Doma::Installer.detect_shell.should be_nil
      ensure
        prev ? (ENV["SHELL"] = prev) : ENV.delete("SHELL")
      end
    end

    it "returns nil when $SHELL is unset" do
      prev = ENV["SHELL"]?
      begin
        ENV.delete("SHELL")
        Doma::Installer.detect_shell.should be_nil
      ensure
        ENV["SHELL"] = prev if prev
      end
    end
  end

  describe ".rc_path_for" do
    it "maps known shells" do
      Doma::Installer.rc_path_for("zsh").should end_with(".zshrc")
      Doma::Installer.rc_path_for("bash").should end_with(".bashrc")
      Doma::Installer.rc_path_for("fish").should end_with("config.fish")
    end

    it "raises for unknown shells" do
      expect_raises(Doma::ValidationError, /unsupported shell/) do
        Doma::Installer.rc_path_for("xonsh")
      end
    end
  end

  describe ".block_for" do
    it "uses eval syntax for bash/zsh" do
      Doma::Installer.block_for("zsh").should contain(%(eval "$(doma setup init zsh)"))
      Doma::Installer.block_for("bash").should contain(%(eval "$(doma setup init bash)"))
    end

    it "uses pipe-source syntax for fish" do
      Doma::Installer.block_for("fish").should contain("doma setup init fish | source")
    end

    it "wraps the block in markers for idempotency" do
      block = Doma::Installer.block_for("zsh")
      block.should contain(Doma::Installer::MARKER)
      block.should contain(Doma::Installer::END_MARKER)
    end
  end

  describe ".plan + .install!" do
    it "appends to a fresh rc file" do
      with_temp_rc do |path|
        plan = stub_plan("zsh", path)
        plan.already_installed.should be_false
        Doma::Installer.install!(plan).should eq(:installed)
        File.read(path).should contain(Doma::Installer::MARKER)
      end
    end

    it "is idempotent — second install! is a no-op" do
      with_temp_rc do |path|
        plan = stub_plan("zsh", path)
        Doma::Installer.install!(plan)

        # Re-plan after the first write so `already_installed` reflects
        # the actual file state, not a stale snapshot.
        replan = stub_plan("zsh", path)
        replan.already_installed.should be_true
        Doma::Installer.install!(replan).should eq(:already_installed)

        File.read(path).scan(Doma::Installer::MARKER).size.should eq(1)
      end
    end

    it "preserves existing rc file content" do
      with_temp_rc do |path|
        File.write(path, "export PATH=$HOME/bin:$PATH\n")
        plan = stub_plan("zsh", path)
        Doma::Installer.install!(plan)

        contents = File.read(path)
        contents.should contain("export PATH=$HOME/bin:$PATH")
        contents.should contain(Doma::Installer::MARKER)
      end
    end

    it "adds a blank line separator when the file lacks a trailing newline" do
      with_temp_rc do |path|
        # Write without a trailing \n on purpose.
        File.write(path, "alias ll='ls -la'")
        plan = stub_plan("zsh", path)
        Doma::Installer.install!(plan)

        contents = File.read(path)
        # Some kind of newline must separate the alias from the marker.
        contents.should match(/alias ll[^\n]*\n+#{Regex.escape(Doma::Installer::MARKER)}/)
      end
    end
  end
end

private def with_temp_rc(&)
  dir = File.tempname("doma-installer")
  FileUtils.mkdir_p(dir)
  rc = File.join(dir, ".zshrc")
  begin
    yield rc
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def stub_plan(shell : String, rc : String) : Doma::Installer::Plan
  block = Doma::Installer.block_for(shell)
  installed = File.exists?(rc) && File.read(rc).includes?(Doma::Installer::MARKER)
  Doma::Installer::Plan.new(shell: shell, rc_path: rc, block: block, already_installed: installed)
end
