require "./spec_helper"

# `TagRenderer.render` is the single source of truth for how `#tag~Nu`
# suffixes look across `list` and `info`. These specs pin both the plain
# text shape (the deterministic, piping-friendly path) and the colored
# variant, forcing Colorize on so the assertions don't depend on whether
# the spec runner's STDOUT happens to be a TTY.
describe Doma::TagRenderer do
  describe ".render" do
    describe "without color" do
      it "prefixes a bare tag with `#`" do
        Doma::TagRenderer.render("work", nil, false).should eq("#work")
      end

      it "appends a `~Nu` suffix for a live TTL" do
        future = Time.utc.to_unix + 7230 # ~2h, comfortably off the boundary
        Doma::TagRenderer.render("work", future, false).should eq("#work~2h")
      end

      it "renders a lapsed TTL as `~expired`" do
        past = Time.utc.to_unix - 100
        Doma::TagRenderer.render("work", past, false).should eq("#work~expired")
      end

      it "emits no ANSI escapes" do
        future = Time.utc.to_unix + 7230
        Doma::TagRenderer.render("work", future, false).should_not contain("\e[")
      end
    end

    describe "with color" do
      around_each do |example|
        prev = Colorize.enabled?
        Colorize.enabled = true
        begin
          example.run
        ensure
          Colorize.enabled = prev
        end
      end

      it "tints the base tag yellow" do
        rendered = Doma::TagRenderer.render("work", nil, true)
        rendered.should contain("\e[33m")
        rendered.should contain("work")
      end

      it "tints a live TTL suffix dark gray" do
        future = Time.utc.to_unix + 7230
        rendered = Doma::TagRenderer.render("work", future, true)
        rendered.should contain("~2h")
        rendered.should contain("\e[90m") # dark_gray for active
        rendered.should_not contain("\e[31m")
      end

      it "tints a lapsed TTL suffix red so it pops" do
        past = Time.utc.to_unix - 100
        rendered = Doma::TagRenderer.render("work", past, true)
        rendered.should contain("~expired")
        rendered.should contain("\e[31m") # red for expired
      end
    end
  end
end
