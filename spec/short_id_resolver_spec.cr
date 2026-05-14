require "./spec_helper"

# Force deterministic short_ids so prefix scenarios are reproducible.
# Migrations populate random hex on insert; we overwrite via raw SQL
# right after add() to pin specific values.
private def pin_short_id(db, path, short_id)
  db.db.exec(
    "UPDATE directories SET short_id = ? WHERE path = ?",
    short_id, Doma::Validator.canonicalize(path)
  )
end

# Direct unit tests for the prefix resolver. The cd/rm commands route
# user input through this module, but until now it was only exercised
# indirectly via cli_commands_spec — none of the branches around
# non-hex input, ambiguity, or case folding had explicit coverage.
describe Doma::ShortIdResolver do
  it "returns nil for non-hex input (a typo'd tag name can't accidentally hit)" do
    with_temp_db do |db|
      Doma::ShortIdResolver.resolve(db, "zzz").should be_nil
      Doma::ShortIdResolver.resolve(db, "abc-xyz").should be_nil
      Doma::ShortIdResolver.resolve(db, "12g4").should be_nil # 'g' isn't hex
    end
  end

  it "returns nil for an empty input" do
    with_temp_db do |db|
      # The regex is `\A[0-9a-fA-F]+\z` (one-or-more), so an empty string
      # short-circuits to nil without touching the DB.
      Doma::ShortIdResolver.resolve(db, "").should be_nil
    end
  end

  it "returns nil when no directory has a matching prefix" do
    with_temp_db do |db|
      tmp = File.tempname("doma-sid-none")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, [] of String)
        pin_short_id(db, tmp, "abc1234")
        Doma::ShortIdResolver.resolve(db, "deadbee").should be_nil
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "resolves a unique full short_id to its path" do
    with_temp_db do |db|
      tmp = File.tempname("doma-sid-full")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, [] of String)
        pin_short_id(db, tmp, "0dc0db9")
        Doma::ShortIdResolver.resolve(db, "0dc0db9")
          .should eq(Doma::Validator.canonicalize(tmp))
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "resolves a unique prefix shorter than the full short_id" do
    with_temp_db do |db|
      tmp = File.tempname("doma-sid-pre")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, [] of String)
        pin_short_id(db, tmp, "0dc0db9")
        Doma::ShortIdResolver.resolve(db, "0dc")
          .should eq(Doma::Validator.canonicalize(tmp))
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "downcases uppercase input so 'AB12' matches 'ab12abc'" do
    with_temp_db do |db|
      tmp = File.tempname("doma-sid-case")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, [] of String)
        pin_short_id(db, tmp, "ab12abc")
        Doma::ShortIdResolver.resolve(db, "AB12")
          .should eq(Doma::Validator.canonicalize(tmp))
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "raises ValidationError listing every match when the prefix is ambiguous" do
    with_temp_db do |db|
      a = File.tempname("doma-sid-ambig-a")
      b = File.tempname("doma-sid-ambig-b")
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)
      begin
        db.add(a, [] of String)
        db.add(b, [] of String)
        pin_short_id(db, a, "0dc0db9")
        pin_short_id(db, b, "0dc1ee5")

        ex = expect_raises(Doma::ValidationError, /ambiguous/) do
          Doma::ShortIdResolver.resolve(db, "0dc")
        end
        # Both candidates must appear in the error so the user can pick
        # a longer prefix without re-running `list`.
        msg = ex.message || ""
        msg.should contain("0dc0db9")
        msg.should contain("0dc1ee5")
      ensure
        FileUtils.rm_rf(a)
        FileUtils.rm_rf(b)
      end
    end
  end

  describe ".looks_like?" do
    it "accepts hex strings in the 4..16 char band" do
      Doma::ShortIdResolver.looks_like?("abcd").should be_true
      Doma::ShortIdResolver.looks_like?("0dc0db9").should be_true
      Doma::ShortIdResolver.looks_like?("0123456789abcdef").should be_true # 16 chars
    end

    it "rejects strings outside the length band" do
      Doma::ShortIdResolver.looks_like?("").should be_false
      Doma::ShortIdResolver.looks_like?("abc").should be_false               # 3
      Doma::ShortIdResolver.looks_like?("0123456789abcdef0").should be_false # 17
    end

    it "rejects non-hex content (the path-or-tag inputs that share these surfaces)" do
      Doma::ShortIdResolver.looks_like?("crystal").should be_false
      Doma::ShortIdResolver.looks_like?("abc-123").should be_false
      Doma::ShortIdResolver.looks_like?("12g4").should be_false
    end

    it "rejects path-shaped input without explicit char guards (regex covers it)" do
      Doma::ShortIdResolver.looks_like?("./abc1234").should be_false
      Doma::ShortIdResolver.looks_like?("~/projects").should be_false
      Doma::ShortIdResolver.looks_like?("abc/1234").should be_false
    end
  end
end
