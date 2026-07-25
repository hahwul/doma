require "./spec_helper"

# Unit coverage for the strict glob matcher. The database GLOB prefilter is
# exercised end-to-end elsewhere (dead_path_frecency_glob_spec); these specs
# pin the pure Crystal semantics — especially the `*` vs `**` distinction and
# the regex-special-character escaping that the SQL layer can't express.
describe Doma::TagGlob do
  describe ".match?" do
    it "treats a glob-free pattern as plain equality" do
      Doma::TagGlob.match?("work", "work").should be_true
      Doma::TagGlob.match?("work", "works").should be_false
      Doma::TagGlob.match?("work", "wor").should be_false
    end

    it "does not interpret regex metacharacters in a glob-free pattern" do
      # No `*`/`?` means the equality short-circuit fires; a `.` here is a
      # literal dot, not a regex wildcard.
      Doma::TagGlob.match?("a.b", "a.b").should be_true
      Doma::TagGlob.match?("a.b", "axb").should be_false
    end

    describe "single `*`" do
      it "matches any run of non-slash characters" do
        Doma::TagGlob.match?("a*", "a").should be_true
        Doma::TagGlob.match?("a*", "abc").should be_true
        Doma::TagGlob.match?("*c", "abc").should be_true
        Doma::TagGlob.match?("a*c", "abxc").should be_true
      end

      it "does not cross a `/` boundary" do
        Doma::TagGlob.match?("a*", "a/b").should be_false
        Doma::TagGlob.match?("work/*", "work/proj").should be_true
        Doma::TagGlob.match?("work/*", "work/proj/sub").should be_false
      end
    end

    describe "double `**`" do
      it "matches across `/` boundaries" do
        Doma::TagGlob.match?("a**", "a/b/c").should be_true
        Doma::TagGlob.match?("work/**", "work/proj/sub").should be_true
        Doma::TagGlob.match?("**", "anything/at/all").should be_true
      end

      it "still matches the no-slash case" do
        Doma::TagGlob.match?("a**", "abc").should be_true
      end

      it "is detected before splitting into two single-star tokens" do
        # `**` followed by a literal must keep the cross-slash semantics.
        Doma::TagGlob.match?("**/leaf", "deep/nested/leaf").should be_true
        Doma::TagGlob.match?("**/leaf", "leaf").should be_false
      end
    end

    describe "`?`" do
      it "matches exactly one non-slash character" do
        Doma::TagGlob.match?("a?c", "abc").should be_true
        Doma::TagGlob.match?("a?c", "ac").should be_false
        Doma::TagGlob.match?("a?c", "abbc").should be_false
      end

      it "does not match a `/`" do
        Doma::TagGlob.match?("a?c", "a/c").should be_false
      end
    end

    describe "regex-special-character escaping" do
      it "treats `.` as a literal when a glob char forces the regex path" do
        Doma::TagGlob.match?("a.*", "a.b").should be_true
        Doma::TagGlob.match?("a.*", "axb").should be_false
      end

      it "escapes `+`, parens and brackets" do
        Doma::TagGlob.match?("a+*", "a+b").should be_true
        Doma::TagGlob.match?("a+*", "aab").should be_false
        Doma::TagGlob.match?("(x)*", "(x)y").should be_true
        Doma::TagGlob.match?("[x]*", "[x]y").should be_true
      end
    end

    it "anchors on both ends (whole-string match)" do
      Doma::TagGlob.match?("a?", "xab").should be_false
      Doma::TagGlob.match?("?b", "abc").should be_false
    end

    describe "oversized patterns" do
      it "rejects a pattern over the length cap with a clean validation error" do
        # Regression: an unbounded pattern (e.g. `**` repeated thousands
        # of times) compiled into a Crystal regex large enough that
        # PCRE2's JIT compiler raised an unhandled ArgumentError instead
        # of matching or failing to match — surfacing to users as an
        # opaque "internal error" rather than a rejected input.
        huge = "*" * (Doma::TagGlob::MAX_PATTERN_LEN + 1)
        expect_raises(Doma::ValidationError, /too long/) do
          Doma::TagGlob.match?(huge, "anything")
        end
      end

      it "accepts a pattern right at the length cap" do
        at_cap = "a" * (Doma::TagGlob::MAX_PATTERN_LEN - 1) + "*"
        Doma::TagGlob.match?(at_cap, "a" * (Doma::TagGlob::MAX_PATTERN_LEN - 1) + "x").should be_true
      end
    end
  end
end
