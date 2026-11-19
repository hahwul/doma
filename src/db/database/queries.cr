# Read paths for the Database: listing/searching directories, resolving
# short-id prefixes and tag globs, hydrating per-entry TTLs, and the
# stats roll-up. All of these are pure reads — no method here mutates
# state. Row→Entry mapping and the SQL-shaping helpers they share live
# at the bottom of the file.
class Doma::Database
  # ---------- Queries ----------

  enum SortBy
    Path
    Recent # most-recently-used first
  end

  # Two query shapes (with/without tag filter), both joining tags via a
  # correlated subquery + GROUP_CONCAT so each Entry comes back fully
  # hydrated in one round trip. Same pattern as `search()` — keeping
  # them consistent means future tweaks (sort orders, additional
  # columns) only need to land in one place.
  def directories(tag : String? = nil, *, sort : SortBy = SortBy::Path, include_expired : Bool = false) : Array(Entry)
    order = order_clause(sort)
    tag_select = include_expired ? TAGS_GROUP_CONCAT_ALL : TAGS_GROUP_CONCAT_ACTIVE

    rows = if tag
             # GLOB (shell-style `*`/`?`) over LIKE so `_`/`%`, valid
             # in tag names, needn't be escaped.
             op = Doma::TagGlob.pattern?(tag) ? "GLOB" : "="
             # The expired-row filter on the JOIN is what hides
             # paths whose `crystal` tag has expired. With
             # include_expired=true we drop it so an operator can
             # audit the full set.
             expired_pred = include_expired ? "1=1" : NOT_EXPIRED_DT
             @db.query_all(
               <<-SQL, tag, as: ENTRY_ROW
                 SELECT DISTINCT #{ENTRY_COLUMNS}, #{tag_select}
                 FROM directories d
                 INNER JOIN directory_tags dt ON dt.directory_id = d.id
                 INNER JOIN tags t ON t.id = dt.tag_id
                 WHERE t.name #{op} ?
                   AND #{expired_pred}
                 #{order}
                 SQL
             )
           else
             @db.query_all(
               <<-SQL, as: ENTRY_ROW
                 SELECT #{ENTRY_COLUMNS}, #{tag_select}
                 FROM directories d
                 #{order}
                 SQL
             )
           end

    rows.map { |row| build_entry(row) }
  end

  record TagSummary, name : String, count : Int64

  # "Name tags": a tag on exactly one directory that is just that
  # directory's (sanitized) basename — what `--auto-tag` produces. They
  # alias one path rather than group a set, so overview listings hide them.
  def name_tags : Set(String)
    @db.query_all(
      <<-SQL, as: {String, String}
        SELECT t.name, MIN(d.basename)
        FROM tags t
        INNER JOIN directory_tags dt ON dt.tag_id = t.id AND #{NOT_EXPIRED_DT}
        INNER JOIN directories d ON d.id = dt.directory_id
        GROUP BY t.id
        HAVING COUNT(*) = 1
        SQL
    ).select { |name, base| Validator.sanitize_tag(base) == name }.map(&.[0]).to_set
  end

  def all_tags : Array(TagSummary)
    # Only active (non-expired) associations count toward a tag's total,
    # and a tag whose associations have all expired drops out entirely —
    # matching what `list -t` already does. Putting
    # NOT_EXPIRED_DT on the JOIN (not WHERE) keeps the LEFT JOIN shape so
    # a fully-expired tag yields cnt = 0, which `HAVING` then filters.
    # Without this, `tags`/`tags --json`/`tags --names` listed phantom
    # tags that `list -t <tag>` could never resolve to a directory.
    @db.query_all(
      <<-SQL, as: {String, Int64}
        SELECT t.name, COUNT(dt.directory_id) AS cnt
        FROM tags t
        LEFT JOIN directory_tags dt ON dt.tag_id = t.id AND #{NOT_EXPIRED_DT}
        GROUP BY t.id
        HAVING cnt > 0
        ORDER BY t.name
        SQL
    ).map { |row| TagSummary.new(row[0], row[1]) }
  end

  # Returns just the tag names — used by the Suggester to build "did
  # you mean …?" hints without round-tripping through TagSummary.
  def tag_names : Array(String)
    @db.query_all("SELECT name FROM tags ORDER BY name", as: String)
  end

  # Single-row lookup by canonical path. Tags include expired ones so
  # `info` and the trash snapshot see every association; callers that
  # need TTLs compose with `tag_expirations`.
  def find_entry(path : String) : Entry?
    @db.query_one?(
      <<-SQL, path, as: ENTRY_ROW
        SELECT #{ENTRY_COLUMNS}, #{TAGS_GROUP_CONCAT_ALL}
        FROM directories d
        WHERE d.path = ?
        SQL
    ).try { |row| build_entry(row) }
  end

  # Resolves a short_id prefix to matching directories. Backs
  # `ShortIdResolver`, so a bare id (`0dc0db9`) or any unique prefix
  # (`0d`) works anywhere a short_id is accepted — `rm`, `info`, and the
  # `add` / `trash restore` redirects. Empty result = no match; multiple
  # = ambiguous. Caller decides what to do with each.
  def directories_by_short_id_prefix(prefix : String) : Array(Entry)
    pattern = "#{prefix}%"
    rows = @db.query_all(
      <<-SQL, pattern, as: ENTRY_ROW
        SELECT #{ENTRY_COLUMNS}, #{TAGS_GROUP_CONCAT_ACTIVE}
        FROM directories d
        WHERE d.short_id LIKE ? ESCAPE '\\'
        ORDER BY d.short_id
        SQL
    )
    rows.map { |row| build_entry(row) }
  end

  # Number of `directory_tags` rows whose TTL has lapsed, optionally
  # only on directories `ids`. The list command passes the entries
  # `--include-expired` would show, so its "N tag(s) hidden by TTL"
  # banner counts what that flag would actually change, not the whole DB.
  def expired_tag_count(ids : Array(Int64)? = nil) : Int64
    return 0_i64 if ids && ids.empty?
    uniq_ids = ids.try(&.uniq) || [] of Int64
    scope = ids ? " AND directory_id IN (#{Doma::Sql.placeholders_for(uniq_ids.size)})" : ""
    @db.scalar(
      "SELECT COUNT(*) FROM directory_tags WHERE #{IS_EXPIRED}#{scope}",
      args: uniq_ids.map(&.as(DB::Any))
    ).as(Int64)
  end

  # Substring search across path, basename, and tag name. Returns
  # deduped entries in `sort` order (path by default).
  #
  # Matched in Crystal, not SQL LIKE: LIKE only folds ASCII case and
  # never normalizes, so an NFD-stored path (what macOS hands back for
  # Hangul/accents) missed an NFC-typed query. NFC + downcase both
  # sides, same as `TUI::Query.contains`.
  #
  # A path / basename hit works regardless of tag expiry; a tag-name
  # hit only counts for tags `directories` returns, i.e. active ones
  # unless `include_expired` — so `-t TAG --include-expired <query>`
  # honors the flag end-to-end.
  def search(query : String, *, sort : SortBy = SortBy::Path, include_expired : Bool = false) : Array(Entry)
    q = query.unicode_normalize(:nfc).downcase
    directories(sort: sort, include_expired: include_expired).select do |e|
      e.path.unicode_normalize(:nfc).downcase.includes?(q) ||
        e.basename.unicode_normalize(:nfc).downcase.includes?(q) ||
        e.tags.any?(&.unicode_normalize(:nfc).downcase.includes?(q))
    end
  end

  # Returns a {tag_name => expires_at_epoch} map for all tags on the
  # given directory whose TTL is still in the future. Used by the
  # exporter so snapshot round-trips preserve TTL information instead
  # of silently promoting timed tags to permanent ones.
  def tag_expirations(directory_id : Int64, *, include_past : Bool = false) : Hash(String, Int64)
    # `include_past` is for callers (like `list --include-expired`)
    # that want already-lapsed TTLs included so they can display
    # them. The default keeps the old export-time behavior of only
    # surfacing future expirations.
    tag_expirations_bulk([directory_id], include_past: include_past)[directory_id]? || {} of String => Int64
  end

  # Bulk variant of `tag_expirations`. Hydrates a `directory_id =>
  # {tag_name => expires_at}` map in one round trip instead of
  # querying once per directory. The list render loop calls
  # `tag_expirations` for *every* entry — at 10k rows that's the
  # difference between ~18ms (1k+ tiny queries) and a single
  # full-table scan that finishes in well under a millisecond.
  #
  # `ids` is intentionally accepted as `Array(Int64)` rather than a
  # Set so callers don't have to convert; we deduplicate internally
  # before the IN-list to avoid quadratic placeholder growth on
  # repeated ids (which the GROUP_CONCAT producer never emits anyway,
  # but the API stays robust).
  def tag_expirations_bulk(ids : Array(Int64), *, include_past : Bool = false) : Hash(Int64, Hash(String, Int64))
    result = {} of Int64 => Hash(String, Int64)
    return result if ids.empty?

    uniq_ids = ids.uniq
    placeholders = Doma::Sql.placeholders_for(uniq_ids.size)
    future_only = include_past ? "" : " AND dt.expires_at > #{NOW_EPOCH}"

    # `Array(DB::Any)` is the type the driver wants for splatted
    # parameters; we widen the Int64 ids into it before passing.
    args = uniq_ids.map { |id| id.as(DB::Any) }
    # Name order, like the tag lists, so `export` output stays diffable.
    rows = @db.query_all(
      "SELECT dt.directory_id, t.name, dt.expires_at FROM directory_tags dt " \
      "INNER JOIN tags t ON t.id = dt.tag_id " \
      "WHERE dt.directory_id IN (#{placeholders}) " \
      "  AND dt.expires_at IS NOT NULL" \
      "#{future_only} " \
      "ORDER BY t.name",
      args: args, as: {Int64, String, Int64}
    )
    rows.each do |row|
      dir_id, name, exp = row
      (result[dir_id] ||= {} of String => Int64)[name] = exp
    end
    result
  end

  record Stats,
    total_directories : Int64,
    total_tags : Int64,
    top_tags : Array(TagSummary),
    recent : Array(NamedTuple(path: String, created_at: Int64)),
    most_used : Array(NamedTuple(path: String, last_used_at: Int64))

  def stats(top_n : Int32 = 10, recent_n : Int32 = 5, used_n : Int32 = 5) : Stats
    total_dirs = @db.scalar("SELECT COUNT(*) FROM directories").as(Int64)
    # Count only tags with at least one active association, so the
    # headline number matches the `Top tags` rows below (and `doma tags`)
    # rather than including tags whose only association has expired.
    total_tags = @db.scalar(
      "SELECT COUNT(DISTINCT dt.tag_id) FROM directory_tags dt WHERE #{NOT_EXPIRED_DT}"
    ).as(Int64)

    # Same expired-aware counting as `all_tags`: ignore expired
    # associations and drop tags left with none.
    top = @db.query_all(
      <<-SQL, top_n, as: {String, Int64}
        SELECT t.name, COUNT(dt.directory_id) AS cnt
        FROM tags t
        LEFT JOIN directory_tags dt ON dt.tag_id = t.id AND #{NOT_EXPIRED_DT}
        GROUP BY t.id
        HAVING cnt > 0
        ORDER BY cnt DESC, t.name ASC
        LIMIT ?
        SQL
    ).map { |row| TagSummary.new(row[0], row[1]) }

    recent = @db.query_all(
      <<-SQL, recent_n, as: {String, Int64}
        SELECT path, created_at
        FROM directories
        ORDER BY created_at DESC, path ASC
        LIMIT ?
        SQL
    ).map { |row| {path: row[0], created_at: row[1]} }

    # Filter out never-used rows (last_used_at = 0) so a fresh DB
    # doesn't show a meaningless "Most used" section listing things
    # the user has never actually opened.
    most_used = @db.query_all(
      <<-SQL, used_n, as: {String, Int64}
        SELECT path, last_used_at
        FROM directories
        WHERE last_used_at > 0
        ORDER BY last_used_at DESC, path ASC
        LIMIT ?
        SQL
    ).map { |row| {path: row[0], last_used_at: row[1]} }

    Stats.new(total_dirs, total_tags, top, recent, most_used)
  end

  # ------------------------------------------------------------------
  # Row-mapping and SQL-shaping helpers shared by the query methods
  # above (and, for `build_entry`, by anything that hydrates an Entry
  # from the standard GROUP_CONCAT column shape).
  # ------------------------------------------------------------------

  private def order_clause(sort : SortBy) : String
    case sort
    in SortBy::Path   then "ORDER BY d.path"
    in SortBy::Recent then "ORDER BY d.last_used_at DESC, d.path ASC"
    end
  end

  private def build_entry(row : EntryRow) : Entry
    id, short_id, path, basename, created_at, last_used_at, joined = row
    tags = joined ? joined.split('\u001f').reject(&.empty?) : [] of String
    Entry.new(id, short_id, path, basename, tags, created_at, last_used_at)
  end
end
