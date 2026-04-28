require "./errors"

module Doma
  # Maps a user-typed short_id prefix back to a registered directory.
  # Shared by `cd` and `rm` so both accept "the 7-char id from `list`"
  # the same way Git accepts a short SHA.
  module ShortIdResolver
    extend self

    # Returns the matching path for a unique prefix, nil for no hits, or
    # raises `ValidationError` on ambiguity. Non-hex inputs short-circuit
    # to nil so a tag typo with non-hex characters can't accidentally
    # resolve to an unrelated directory.
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
