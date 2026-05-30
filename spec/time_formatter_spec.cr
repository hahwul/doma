require "./spec_helper"

describe Doma::TimeFormatter do
  describe ".absolute" do
    it "formats a normal epoch as ISO-ish local time" do
      # 2001-09-09 01:46:40 UTC — assert on the date, which is stable
      # regardless of the runner's timezone offset.
      Doma::TimeFormatter.absolute(1_000_000_000_i64).should match(/^2001-09-0[89] \d{2}:\d{2}$/)
    end

    it "returns a marker instead of crashing on an out-of-range epoch" do
      # `Time.unix` raises ArgumentError outside year 1–9999; a corrupted
      # row or hand-crafted import must not take down `list`/`info`.
      Doma::TimeFormatter.absolute(99_999_999_999_999_i64).should eq("(invalid date)")
      Doma::TimeFormatter.absolute(-99_999_999_999_999_i64).should eq("(invalid date)")
    end
  end

  describe ".relative_past" do
    it "renders sub-minute deltas in seconds" do
      # Don't pin the exact count — a second-boundary crossing between the
      # two `Time.utc` reads would make it flaky; assert the seconds branch.
      now = Time.utc.to_unix
      Doma::TimeFormatter.relative_past(now - 30).should match(/^\d+s ago$/)
    end

    it "renders larger deltas with the coarser unit" do
      now = Time.utc.to_unix
      Doma::TimeFormatter.relative_past(now - 7200).should eq("2h ago")
    end

    it "renders 'just now' for a future timestamp instead of a negative count" do
      # Clock skew (or a row imported from a machine whose clock was ahead)
      # makes the delta negative; the old code printed "-Ns ago".
      future = Time.utc.to_unix + 5000
      Doma::TimeFormatter.relative_past(future).should eq("just now")
    end

    it "renders the just-added present moment as a seconds count, not 'just now'" do
      # delta == 0 is the present, not the future — it stays in the
      # seconds branch ("0s ago"). Only a strictly-negative (future) delta
      # collapses to "just now".
      Doma::TimeFormatter.relative_past(Time.utc.to_unix).should match(/^\d+s ago$/)
    end
  end
end
