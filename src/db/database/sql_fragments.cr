# Shared SQL fragments for the Database partials.
#
# Centralized so a future schema change to the TTL representation
# (precision shift, NULL semantics, column rename) lands in one place.
# Each predicate is parenthesized so it composes safely after `AND`/`OR`
# in a longer WHERE. These constants live on `Doma::Database` itself, so
# the mutation/maintenance/query partials all reference them unqualified.
class Doma::Database
  # Server-side "now" in seconds since epoch. Used by every TTL
  # predicate; named so the bare `strftime('%s','now')` literal stops
  # appearing scattered across queries.
  NOW_EPOCH = "strftime('%s','now')"

  # "tag row is still active" — used by reads that should hide
  # already-expired tag associations. `dt` here refers to the
  # `directory_tags` alias used consistently across the joined
  # queries below.
  NOT_EXPIRED_DT = "(dt.expires_at IS NULL OR dt.expires_at > #{NOW_EPOCH})"

  # "tag row has lapsed" — used by writes that sweep expired rows and
  # by the count surfaced to users. _DT variant is for queries that
  # have already aliased `directory_tags` as `dt`; the unqualified
  # form is for `WHERE` on the table directly.
  IS_EXPIRED_DT = "(dt.expires_at IS NOT NULL AND dt.expires_at <= #{NOW_EPOCH})"
  IS_EXPIRED    = "(expires_at IS NOT NULL AND expires_at <= #{NOW_EPOCH})"

  # The scalar column list every Entry-hydrating read selects, in the
  # exact order `build_entry` destructures. Centralized so adding a
  # column to `Entry` is one edit here plus one in `build_entry`,
  # rather than four SELECTs drifting apart. Always followed by a
  # TAGS_GROUP_CONCAT_* variant as the trailing column. Assumes the
  # `directories` table is aliased `d`.
  ENTRY_COLUMNS = "d.id, d.short_id, d.path, d.basename, d.created_at, d.last_used_at"

  # The row shape matching `ENTRY_COLUMNS` plus the trailing
  # GROUP_CONCAT column (nullable — a directory with no tags
  # concatenates to NULL). Kept beside the column list so the two can't
  # fall out of sync.
  #
  # Two spellings of the same thing because they're used in two
  # different positions: crystal-db's `as:` takes a *value* (a tuple of
  # class objects), while a method's type restriction takes a *type*.
  # An alias can't stand in for the former, so both live here rather
  # than one being re-typed at each call site.
  ENTRY_ROW = {Int64, String, String, String, Int64, Int64, String?}
  alias EntryRow = {Int64, String, String, String, Int64, Int64, String?}

  # Tags are joined with the unit-separator (0x1f) rather than a comma
  # so that a tag containing a comma — which our validator rejects
  # today, but might allow in a future schema bump — wouldn't tear the
  # split apart. See `build_entry` for the matching split.
  #
  # GROUP_CONCAT subquery that hydrates the per-directory tag list in
  # one shot. Uses the `dt2` alias so it can be embedded inside an
  # outer query that already uses `dt`. Two variants:
  #   ACTIVE — only tags whose row is not expired (the default)
  #   ALL    — every tag, expired or not (for `--include-expired`)
  TAGS_GROUP_CONCAT_ACTIVE = <<-SQL
    (SELECT GROUP_CONCAT(name, X'1f')
     FROM (SELECT t2.name
           FROM tags t2
           INNER JOIN directory_tags dt2 ON dt2.tag_id = t2.id
           WHERE dt2.directory_id = d.id
             AND (dt2.expires_at IS NULL OR dt2.expires_at > #{NOW_EPOCH})
           ORDER BY t2.name)) AS joined_tags
    SQL

  TAGS_GROUP_CONCAT_ALL = <<-SQL
    (SELECT GROUP_CONCAT(name, X'1f')
     FROM (SELECT t2.name
           FROM tags t2
           INNER JOIN directory_tags dt2 ON dt2.tag_id = t2.id
           WHERE dt2.directory_id = d.id
           ORDER BY t2.name)) AS joined_tags
    SQL

  # Conflict action for merge-style INSERTs into `directory_tags`
  # (`move` onto an existing path, `rename` onto an existing tag).
  # When the destination already has the tag, keep whichever lifetime
  # is more permissive: NULL/permanent beats any TTL, and between two
  # TTLs the later epoch wins.
  MERGE_KEEP_LONGER_TTL = <<-SQL
    ON CONFLICT(directory_id, tag_id) DO UPDATE SET expires_at =
      CASE
        WHEN excluded.expires_at IS NULL OR directory_tags.expires_at IS NULL THEN NULL
        ELSE MAX(excluded.expires_at, directory_tags.expires_at)
      END
    SQL
end
