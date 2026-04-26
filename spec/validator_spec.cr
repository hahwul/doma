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
  end
end
