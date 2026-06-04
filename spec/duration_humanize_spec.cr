require "./spec_helper"

# `parse_seconds!` and friends are covered in ttl_spec; this file fills the
# remaining gap — `humanize_remaining`, the renderer-facing inverse that
# turns an absolute `expires_at` epoch back into the compact `Nu` form.
# Offsets are chosen comfortably away from each bucket boundary so the
# one-second-of-clock-drift between building the input and reading
# `Time.utc` inside the method can't flip a bucket.
describe Doma::Duration do
  describe ".humanize_remaining" do
    it "reports a lapsed deadline as 'expired'" do
      Doma::Duration.humanize_remaining(Time.utc.to_unix - 1).should eq("expired")
    end

    it "treats exactly-now as expired (delta <= 0)" do
      Doma::Duration.humanize_remaining(Time.utc.to_unix).should eq("expired")
    end

    it "renders sub-minute remainders in seconds" do
      Doma::Duration.humanize_remaining(Time.utc.to_unix + 30).should match(/\A\d+s\z/)
    end

    it "renders sub-hour remainders in minutes" do
      # 150s -> 2m, and 149s (one tick later) still floors to 2m.
      Doma::Duration.humanize_remaining(Time.utc.to_unix + 150).should eq("2m")
    end

    it "renders sub-day remainders in hours" do
      Doma::Duration.humanize_remaining(Time.utc.to_unix + 7230).should eq("2h")
    end

    it "renders sub-week remainders in days" do
      Doma::Duration.humanize_remaining(Time.utc.to_unix + (2 * 86_400 + 3600)).should eq("2d")
    end

    it "renders week-or-longer remainders in weeks" do
      Doma::Duration.humanize_remaining(Time.utc.to_unix + (3 * 604_800 + 3600)).should eq("3w")
    end

    it "round-trips a parsed duration back through the humanizer" do
      # 3h parses to 10800s; humanizing now+10800 floors to "3h" (or "2h"
      # if a clock tick slips in between) — either way it stays in hours.
      secs = Doma::Duration.parse_seconds!("3h")
      result = Doma::Duration.humanize_remaining(Time.utc.to_unix + secs)
      ["2h", "3h"].should contain(result)
    end
  end
end
