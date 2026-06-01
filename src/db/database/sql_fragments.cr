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
end
