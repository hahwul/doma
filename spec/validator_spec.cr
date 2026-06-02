require "./spec_helper"

describe Doma::Validator do
  describe ".tag!" do
    it "accepts a normal tag" do
      Doma::Validator.tag!("crystal").should eq("crystal")
    end

    it "trims surrounding whitespace" do
      Doma::Validator.tag!("  cli  ").should eq("cli")
    end

    it "rejects empty tags" do
      expect_raises(Doma::ValidationError, /empty/) { Doma::Validator.tag!("   ") }
    end

    it "rejects whitespace inside the tag" do
      expect_raises(Doma::ValidationError) { Doma::Validator.tag!("a b") }
    end

    it "rejects commas (reserved as a separator at the CLI)" do
      expect_raises(Doma::ValidationError) { Doma::Validator.tag!("a,b") }
    end

    it "allows valid punctuation" do
      Doma::Validator.tag!("foo-bar.baz_v1+rc").should eq("foo-bar.baz_v1+rc")
    end

    it "rejects tags that don't start alphanumeric" do
      expect_raises(Doma::ValidationError) { Doma::Validator.tag!("-leading") }
    end

    it "rejects oversized tags" do
      expect_raises(Doma::ValidationError, /exceeds/) { Doma::Validator.tag!("a" * 65) }
    end
  end

  describe ".tags!" do
    it "splits comma-separated input and de-duplicates" do
      Doma::Validator.tags!(["crystal,cli", "cli", " web "]).should eq(["crystal", "cli", "web"])
    end

    it "drops empties without raising" do
      Doma::Validator.tags!([",,crystal,"]).should eq(["crystal"])
    end
  end

  describe ".path!" do
    it "expands ~/." do
      result = Doma::Validator.path!(Dir.current, must_exist: true)
      result.should start_with('/')
    end

    it "raises when the directory is missing" do
      expect_raises(Doma::ValidationError, /not a directory/) do
        Doma::Validator.path!("/no/such/dir/anywhere")
      end
    end

    it "skips existence check when must_exist=false" do
      result = Doma::Validator.path!("/no/such/dir/anywhere", must_exist: false)
      result.should eq("/no/such/dir/anywhere")
    end

    it "raises on whitespace-only input" do
      expect_raises(Doma::ValidationError, /empty/) do
        Doma::Validator.path!("   ")
      end
    end
  end

  describe ".canonicalize edges" do
    it "resolves '..' segments" do
      Doma::Validator.canonicalize("/tmp/foo/..").should eq(Doma::Validator.canonicalize("/tmp"))
    end

    it "preserves the bare root path" do
      Doma::Validator.canonicalize("/").should eq("/")
    end

    it "expands ~ to $HOME" do
      result = Doma::Validator.canonicalize("~")
      result.should eq(ENV["HOME"])
    end

    it "is idempotent" do
      once = Doma::Validator.canonicalize("/tmp/")
      twice = Doma::Validator.canonicalize(once)
      once.should eq(twice)
    end

    it "resolves symlinks on the closest existing ancestor when the leaf is missing" do
      # Without the ancestor walk, `move --allow-missing` to a not-yet-
      # created path would store `/tmp/foo` while a later `add` of the
      # same dir (once it exists) would canonicalize to `/private/tmp/foo`
      # via realpath, leaving two rows for the same physical directory.
      base = File.tempname("doma-canon-base")
      FileUtils.mkdir_p(base)
      link = "#{base}-link"
      File.symlink(base, link)
      begin
        # Sanity: the symlink itself should resolve through the realpath
        # branch, since it exists on disk.
        Doma::Validator.canonicalize(link).should eq(File.realpath(base))

        # The interesting case: a child path that doesn't exist yet must
        # still get its ancestor symlink-resolved.
        nonexistent_child = File.join(link, "child", "deeper")
        expected = File.join(File.realpath(base), "child", "deeper")
        Doma::Validator.canonicalize(nonexistent_child).should eq(expected)
      ensure
        File.delete(link) if File.symlink?(link)
        FileUtils.rm_rf(base)
      end
    end
  end

  describe ".tag! boundaries" do
    it "accepts a 64-byte ASCII tag exactly" do
      tag = "a" * 64
      Doma::Validator.tag!(tag).should eq(tag)
    end

    it "rejects 65 bytes by one" do
      expect_raises(Doma::ValidationError, /exceeds/) do
        Doma::Validator.tag!("a" * 65)
      end
    end

    it "accepts a single alphanumeric character" do
      Doma::Validator.tag!("a").should eq("a")
      Doma::Validator.tag!("9").should eq("9")
    end

    it "accepts every allowed punctuation character" do
      # Each punctuation char must come *after* an alphanumeric. `/` is a
      # hierarchy separator, so it's exercised with a following segment
      # rather than as a trailing slash (which is rejected below).
      Doma::Validator.tag!("a_").should eq("a_")
      Doma::Validator.tag!("a.").should eq("a.")
      Doma::Validator.tag!("a-").should eq("a-")
      Doma::Validator.tag!("a+").should eq("a+")
      Doma::Validator.tag!("a:").should eq("a:")
      Doma::Validator.tag!("a/b").should eq("a/b")
    end

    it "rejects empty path segments (trailing or doubled '/')" do
      # An empty hierarchy segment renders as a blank/`/` node under
      # `tags --tree`, so it's rejected at the boundary.
      ["a/", "a//b", "a/b/", "a///b"].each do |bad|
        expect_raises(Doma::ValidationError, /empty path segment/) do
          Doma::Validator.tag!(bad)
        end
      end
    end

    it "rejects newline / tab / NUL" do
      ["a\nb", "a\tb", "a\0b"].each do |bad|
        expect_raises(Doma::ValidationError) { Doma::Validator.tag!(bad) }
      end
    end
  end

  describe ".tags! edges" do
    it "returns an empty array on empty input" do
      Doma::Validator.tags!([] of String).should be_empty
    end

    it "returns an empty array when every entry is whitespace/empty" do
      Doma::Validator.tags!(["", "  ", ",", " , ,"]).should be_empty
    end
  end

  describe ".sanitize_tag edges" do
    it "strips non-ASCII characters wholesale" do
      # Korean characters are stripped; whatever ASCII remains is checked.
      Doma::Validator.sanitize_tag("크리스탈crystal").should eq("crystal")
    end

    it "drops a tag composed only of stripped characters" do
      Doma::Validator.sanitize_tag("크리스탈").should be_nil
    end

    it "trims to MAX_TAG_LEN" do
      raw = "a" * 100
      result = Doma::Validator.sanitize_tag(raw)
      result.should_not be_nil
      result.try(&.size).should eq(Doma::Validator::MAX_TAG_LEN)
    end

    it "tolerates entirely-numeric input" do
      Doma::Validator.sanitize_tag("12345").should eq("12345")
    end

    it "normalizes empty path segments away rather than producing them" do
      # Derived tags must satisfy the same no-empty-segment rule `tag!`
      # enforces: doubled slashes collapse, trailing slashes drop.
      Doma::Validator.sanitize_tag("a//b").should eq("a/b")
      Doma::Validator.sanitize_tag("a/").should eq("a")
      Doma::Validator.sanitize_tag("a/b/").should eq("a/b")
    end
  end
end
