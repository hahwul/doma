require "./errors"

module Doma
  # Maps a user-typed short_id prefix back to a registered directory.
  # Shared by `cd` and `rm` so both accept "the 7-char id from `list`"
  # the same way Git accepts a short SHA.
  module ShortIdResolver
    extend self

    # 4 keeps random tag names like `abcd` from being misread as ids;
    # 16 is the full short_id length we ever generate. Anything outside
    # that band is definitely something else.
    SHAPE = /\A[0-9a-fA-F]{4,16}\z/

    # True when `raw` is shaped like a short_id (or unique-prefix of one)
    # the user might have copied out of `list`/`info` output. The hex-only
    # regex already rules out `/`, `.`, `~`, and other path-ish chars, so
    # callers don't need to belt-and-suspender those explicitly.
    def looks_like?(raw : String) : Bool
      raw.matches?(SHAPE)
    end

    # Returns the matching path for a unique prefix, nil for no hits, or
    # raises `ValidationError` on ambiguity. Non-hex inputs short-circuit
    # to nil so a tag typo with non-hex characters can't accidentally
    # resolve to an unrelated directory. Note `resolve` accepts shorter
    # prefixes than `looks_like?` (1+ hex chars) — `looks_like?` is the
    # shape gate for "user probably meant an id", whereas `resolve` is
    # the lookup itself.
    def resolve(db : Doma::Database, prefix : String) : String?
      return unless prefix.matches?(/\A[0-9a-fA-F]+\z/)

      hits = db.directories_by_short_id_prefix(prefix.downcase)
      case hits.size
      when 0
        nil
      when 1
        hits.first.path
      else
        list = hits.map(&.short_id).join(", ")
        raise Doma::ValidationError.new(
          "short_id prefix '#{prefix}' is ambiguous (matches: #{list})"
        )
      end
    end
  end
end
