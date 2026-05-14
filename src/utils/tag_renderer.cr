require "colorize"
require "./duration"

module Doma
  # Shared formatter for "#tag" plus the optional `~Nu` TTL suffix.
  # Lives here so `list`, `info`, and any future surface that prints
  # tags stay in lockstep on the suffix shape and color choices —
  # previously each command carried its own identical copy and they
  # could drift apart silently.
  module TagRenderer
    extend self

    # Decorate `#tag` with a `~3d` / `~expired` suffix when the tag has
    # a TTL. The suffix uses the same compact `Nu` form the parser
    # accepts, so a glance at the listing tells you what to renew. An
    # already-lapsed TTL renders red instead of dim so it pops next to
    # active rows when --include-expired surfaces them.
    def render(tag : String, expires_at : Int64?, color : Bool) : String
      base = color ? "##{tag}".colorize(:yellow).to_s : "##{tag}"
      return base unless expires_at
      remaining = Doma::Duration.humanize_remaining(expires_at)
      suffix = "~#{remaining}"
      return "#{base}#{suffix}" unless color
      tinted = remaining == "expired" ? suffix.colorize(:red) : suffix.colorize(:dark_gray)
      "#{base}#{tinted}"
    end
  end
end
