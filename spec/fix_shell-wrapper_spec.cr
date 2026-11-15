require "./spec_helper"

# Regressions for the shell wrapper (`doma setup init`) and
# `doma setup install`. Wrapper specs drive the real shells against the
# built binary; each one is skipped when that shell isn't installed.

private SW_BIN = File.expand_path("../bin/doma", __DIR__)

private def sw_sh(shell : String, script : String, home : String, extra = {} of String => String)
  env = {
    "DOMA_HOME"   => home,
    "DOMA_DB"     => File.join(home, "doma.db"),
    "DOMA_CONFIG" => File.join(home, "config.toml"),
    "DOMA_NO_TUI" => "1",
    "PATH"        => "#{File.dirname(SW_BIN)}:#{ENV["PATH"]}",
  }.merge(extra)
  argv = shell == "fish" ? ["--no-config", "-c", script] : (shell == "zsh" ? ["-f", "-c", script] : ["--norc", "--noprofile", "-c", script])
  sout = IO::Memory.new
  err = IO::Memory.new
  st = Process.run(shell, argv, env: env, input: Process::Redirect::Close, output: sout, error: err)
  {out: sout.to_s, err: err.to_s, status: st}
end

# Seeds tags: solo (one dir), work (two dirs), gone (a deleted dir).
private def sw_seed(&)
  home = File.tempname("doma-sw")
  FileUtils.mkdir_p(home)
  begin
    {"solo" => "solo", "work1" => "work", "work2" => "work", "gone" => "gone"}.each do |dir, tag|
      path = File.join(home, dir)
      Dir.mkdir_p(path)
      Process.run(SW_BIN, ["add", path, "-t", tag], env: {"DOMA_HOME" => home, "DOMA_DB" => File.join(home, "doma.db"), "DOMA_CONFIG" => File.join(home, "config.toml")})
    end
    Dir.delete(File.join(home, "gone"))
    yield File.realpath(home)
  ensure
    FileUtils.rm_rf(home)
  end
end

private POSIX_INIT = %(eval "$(doma setup init bash)"\n)
private FISH_INIT  = "doma setup init fish | source\n"

describe "shell wrapper regressions" do
  # /bin/bash is 3.2 on macOS: empty arrays trip `set -u` there.
  {"bash", "zsh", "/bin/bash"}.each do |shell|
    it "[#{shell}] cd --help prints usage, globals before cd, extra args, cd failure, aliased cat" do
      pending! "binary not built" unless File.exists?(SW_BIN)
      pending! "#{shell} not installed" unless Process.find_executable(shell)
      sw_seed do |home|
        script = <<-SH
          #{shell.ends_with?("bash") ? "shopt -s expand_aliases" : ""}
          alias cat="cat -n"
          #{POSIX_INIT}
          set -u
          doma tags >/dev/null; echo "tags=$?"
          doma cd; echo "bare=$?"
          doma cd --help; echo "help=$?"
          doma -q cd solo; echo "q=$? $PWD"; cd /
          doma cd work --first; echo "first=$? $PWD"; cd /
          doma cd gone; echo "gone=$?"
          doma cd gone && echo "CHAINED"
          SH
        r = sw_sh(shell, script, home)
        r[:out].should contain("Usage: doma cd")
        r[:out].should contain("help=0")
        r[:out].should contain("tags=0")
        r[:err].should_not contain("unbound")
        r[:err].should_not contain("parameter not set")
        r[:out].should contain("q=0 #{home}/solo")
        r[:out].should match(/first=0 #{Regex.escape(home)}\/work\d/)
        r[:out].should_not contain("gone=0")
        r[:out].should_not contain("CHAINED")
      end
    end
  end

  it "[fish] same behaviors" do
    pending! "binary not built" unless File.exists?(SW_BIN)
    pending! "fish not installed" unless Process.find_executable("fish")
    sw_seed do |home|
      script = <<-FISH
        function cat; command cat -n $argv; end
        #{FISH_INIT}
        doma cd -h; echo "help=$status"
        doma -q cd solo; echo "q=$status $PWD"; cd /
        doma cd work --first; echo "first=$status $PWD"; cd /
        doma cd gone; echo "gone=$status"
        FISH
      r = sw_sh("fish", script, home)
      r[:out].should contain("Usage: doma cd")
      r[:out].should contain("help=0")
      r[:out].should contain("q=0 #{home}/solo")
      r[:out].should match(/first=0 #{Regex.escape(home)}\/work\d/)
      r[:out].should_not contain("gone=0")
    end
  end
end

describe "setup install regressions" do
  it "[fish] honors XDG_CONFIG_HOME" do
    prev = ENV["XDG_CONFIG_HOME"]?
    ENV["XDG_CONFIG_HOME"] = "/x/cfg"
    begin
      Doma::Installer.rc_path_for("fish").should eq("/x/cfg/fish/config.fish")
    ensure
      prev ? (ENV["XDG_CONFIG_HOME"] = prev) : ENV.delete("XDG_CONFIG_HOME")
    end
  end

  it "shell-quotes the `source` hint when HOME has a space" do
    pending! "binary not built" unless File.exists?(SW_BIN)
    home = File.tempname("doma sw home")
    FileUtils.mkdir_p(home)
    begin
      err = IO::Memory.new
      Process.run(SW_BIN, ["setup", "install", "bash", "-y"], env: {"HOME" => home, "DOMA_HOME" => home}, output: err, error: err)
      err.to_s.should contain("source #{Process.quote(File.join(home, ".bashrc"))}")
      err.to_s.should contain("source '")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "treats Ctrl-D at the confirm prompt as no" do
    pending! "binary not built" unless File.exists?(SW_BIN)
    pending! "python3 not installed" unless Process.find_executable("python3")
    home = File.tempname("doma-sw-eof")
    FileUtils.mkdir_p(home)
    begin
      py = <<-'PY'
        import os, pty, sys, time
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(sys.argv[1], sys.argv[1:])
        time.sleep(0.5); os.write(fd, b"\x04")
        while True:
            try:
                if not os.read(fd, 4096): break
            except OSError: break
        sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
        PY
      st = Process.run("python3", ["-I", "-c", py, SW_BIN, "setup", "install", "bash"], env: {"HOME" => home, "DOMA_HOME" => home})
      st.exit_code.should eq(1)
      File.exists?(File.join(home, ".bashrc")).should be_false
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
