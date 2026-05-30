require "./spec_helper"

private def with_temp_config(content : String, &)
  dir = File.tempname("doma-cfg")
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "config.yml")
  File.write(path, content)
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Doma::Config do
  it "expands `~` in the default home path" do
    prev_home = ENV["DOMA_HOME"]?
    ENV.delete("DOMA_HOME")
    begin
      Doma::Config.home.should start_with(ENV["HOME"])
      Doma::Config.home.should_not contain("~")
    ensure
      ENV["DOMA_HOME"] = prev_home if prev_home
    end
  end

  it "expands `~` in DOMA_DB env" do
    prev = ENV["DOMA_DB"]?
    ENV["DOMA_DB"] = "~/somewhere/doma.db"
    begin
      Doma::Config.db_path.should eq(File.join(ENV["HOME"], "somewhere/doma.db"))
    ensure
      prev ? (ENV["DOMA_DB"] = prev) : ENV.delete("DOMA_DB")
    end
  end

  it "falls back to the default when DOMA_DB is blank" do
    prev_db = ENV["DOMA_DB"]?
    prev_home = ENV["DOMA_HOME"]?
    home = File.tempname("doma-cfg-home")
    FileUtils.mkdir_p(home)
    ENV["DOMA_HOME"] = home
    ENV["DOMA_DB"] = ""
    Doma::Settings.current = nil
    begin
      Doma::Config.db_path.should eq(File.join(home, "doma.db"))
    ensure
      ENV.delete("DOMA_DB")
      ENV["DOMA_DB"] = prev_db if prev_db
      prev_home ? (ENV["DOMA_HOME"] = prev_home) : ENV.delete("DOMA_HOME")
      Doma::Settings.current = nil
      FileUtils.rm_rf(home)
    end
  end

  it "falls back to the default when Settings.db_path is blank" do
    prev_home = ENV["DOMA_HOME"]?
    prev_db = ENV["DOMA_DB"]?
    ENV.delete("DOMA_DB")
    home = File.tempname("doma-cfg-home")
    FileUtils.mkdir_p(home)
    ENV["DOMA_HOME"] = home
    settings = Doma::Settings.new
    settings.db_path = ""
    Doma::Settings.current = settings
    begin
      Doma::Config.db_path.should eq(File.join(home, "doma.db"))
    ensure
      Doma::Settings.current = nil
      prev_home ? (ENV["DOMA_HOME"] = prev_home) : ENV.delete("DOMA_HOME")
      ENV["DOMA_DB"] = prev_db if prev_db
      FileUtils.rm_rf(home)
    end
  end

  it "treats a blank DOMA_HOME as unset (not the cwd)" do
    prev_home = ENV["DOMA_HOME"]?
    ENV["DOMA_HOME"] = ""
    begin
      # A set-but-empty value used to be truthy and resolve to the cwd via
      # `File.expand_path("")`; it must fall back to the default instead.
      Doma::Config.home.should eq(File.expand_path(Doma::Config::DEFAULT_DIR, home: true))
      Doma::Config.home.should_not eq(Dir.current)
    ensure
      prev_home ? (ENV["DOMA_HOME"] = prev_home) : ENV.delete("DOMA_HOME")
    end
  end

  it "treats a blank DOMA_CONFIG as unset (falls back to home/config.yml)" do
    prev_cfg = ENV["DOMA_CONFIG"]?
    prev_home = ENV["DOMA_HOME"]?
    home = File.tempname("doma-cfg-home2")
    FileUtils.mkdir_p(home)
    ENV["DOMA_HOME"] = home
    ENV["DOMA_CONFIG"] = ""
    begin
      Doma::Config.config_path.should eq(File.join(home, "config.yml"))
    ensure
      prev_cfg ? (ENV["DOMA_CONFIG"] = prev_cfg) : ENV.delete("DOMA_CONFIG")
      prev_home ? (ENV["DOMA_HOME"] = prev_home) : ENV.delete("DOMA_HOME")
      FileUtils.rm_rf(home)
    end
  end
end

describe Doma::Settings do
  it "uses defaults when the file is missing" do
    settings = Doma::Settings.load("/no/such/config.yml")
    settings.db_path.should be_nil
    settings.selector.should eq(Doma::Settings::SelectorMode::Auto)
    settings.auto_tag.basename.should be_false
    settings.auto_tag.git.should be_false
  end

  it "loads partial config with defaults filling gaps" do
    with_temp_config("auto_tag:\n  git: true\n") do |path|
      settings = Doma::Settings.load(path)
      settings.auto_tag.git.should be_true
      settings.auto_tag.basename.should be_false
      settings.selector.should eq(Doma::Settings::SelectorMode::Auto)
    end
  end

  it "parses every supported field" do
    with_temp_config(
      <<-YML
        db_path: /tmp/doma.db
        selector: builtin
        auto_tag:
          basename: true
          git: true
        YML
    ) do |path|
      settings = Doma::Settings.load(path)
      settings.db_path.should eq("/tmp/doma.db")
      settings.selector.should eq(Doma::Settings::SelectorMode::Builtin)
      settings.auto_tag.basename.should be_true
      settings.auto_tag.git.should be_true
    end
  end

  it "raises ConfigError on malformed YAML" do
    with_temp_config("this: is: not: valid: yaml: [\n") do |path|
      expect_raises(Doma::ConfigError, /invalid config/) do
        Doma::Settings.load(path)
      end
    end
  end

  it "rejects unknown fields (typo protection via strict)" do
    with_temp_config("dbpath: /tmp/x.db\n") do |path|
      expect_raises(Doma::ConfigError) do
        Doma::Settings.load(path)
      end
    end
  end

  it "surfaces unknown-key errors with the offending key and valid keys" do
    with_temp_config("dbpath: /tmp/x.db\n") do |path|
      ex = expect_raises(Doma::ConfigError) do
        Doma::Settings.load(path)
      end
      msg = ex.message || ""
      msg.should contain("unknown key 'dbpath'")
      msg.should contain("db_path") # one of the suggestions
      msg.should contain("line 1")
    end
  end

  it "surfaces invalid enum values with the allowed set" do
    with_temp_config("selector: panic\n") do |path|
      ex = expect_raises(Doma::ConfigError) do
        Doma::Settings.load(path)
      end
      msg = ex.message || ""
      msg.should contain("invalid value 'panic'")
      msg.should contain("auto")
      msg.should contain("builtin")
      msg.should contain("first")
    end
  end
end
