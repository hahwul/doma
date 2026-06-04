require "./spec_helper"

# `suggest`/`hint_for` are covered in move_suggester_spec; this file pins
# `tag_hint_for`, the tag-aware variant that nudges users toward the
# hierarchical-glob form (`-t 'work/*'`) when they type a parent tag that
# has children but no literal match.
describe Doma::Suggester do
  describe ".tag_hint_for" do
    it "suggests the hierarchical glob when children exist under the input" do
      hint = Doma::Suggester.tag_hint_for("work", ["work/proj-a", "work/proj-b"])
      hint.should eq("did you mean 'work/*'? (matches work/proj-a, work/proj-b)")
    end

    it "samples only the first two children and elides the rest" do
      hint = Doma::Suggester.tag_hint_for("work", ["work/a", "work/b", "work/c"])
      hint.should eq("did you mean 'work/*'? (matches work/a, work/b, ...)")
    end

    it "does not elide when there are exactly two children" do
      hint = Doma::Suggester.tag_hint_for("work", ["work/a", "work/b"])
      hint.should eq("did you mean 'work/*'? (matches work/a, work/b)")
    end

    it "falls back to a typo hint when no children share the prefix" do
      Doma::Suggester.tag_hint_for("crystl", ["crystal", "go"])
        .should eq("Did you mean 'crystal'?")
    end

    it "returns nil for empty input" do
      Doma::Suggester.tag_hint_for("", ["work/a"]).should be_nil
    end

    it "skips the glob hint when the input already contains a glob char" do
      # `*`/`?` mean the user is already gloving; don't re-suggest a glob.
      Doma::Suggester.tag_hint_for("work*", ["work/a", "work/b"]).should be_nil
      Doma::Suggester.tag_hint_for("wor?", ["work/a"]).should be_nil
    end

    it "skips the glob hint when the input itself is hierarchical" do
      # An input that already contains `/` isn't a bare parent tag, so the
      # glob nudge doesn't apply; it falls through to the typo path.
      Doma::Suggester.tag_hint_for("work/pro", ["work/proj"])
        .should eq("Did you mean 'work/proj'?")
    end

    it "returns nil when nothing matches and no children exist" do
      Doma::Suggester.tag_hint_for("zzz", ["work/a", "go"]).should be_nil
    end
  end
end
