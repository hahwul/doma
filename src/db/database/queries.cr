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
    order = order_clause(sort, prefix: "d.")
    tag_select = include_expired ? TAGS_GROUP_CONCAT_ALL : TAGS_GROUP_CONCAT_ACTIVE

    rows = if tag
             op = tag_match_clause(tag)
             # The expired-row filter on the JOIN is what hides
             # paths whose `crystal` tag has expired. With
             # include_expired=true we drop it so an operator can
             # audit the full set.
             expired_pred = include_expired ? "1=1" : NOT_EXPIRED_DT
             @db.query_all(
               <<-SQL, tag, as: {Int64, String, String, String, String?}
                 SELECT DISTINCT d.id, d.short_id, d.path, d.basename, #{tag_select}
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
               <<-SQL, as: {Int64, String, String, String, String?}
                 SELECT d.id, d.short_id, d.path, d.basename, #{tag_select}
                 FROM directories d
                 #{order}
                 SQL
             )
           end

    rows.map { |row| build_entry(row) }
  end

  def tags_for(directory_id : Int64) : Array(String)
    @db.query_all(
      "SELECT t.name FROM tags t " \
      "INNER JOIN directory_tags dt ON dt.tag_id = t.id " \
      "WHERE dt.directory_id = ? ORDER BY t.name",
      directory_id, as: String
    )
  end

  record TagSummary, name : String, count : Int64

  def all_tags : Array(TagSummary)
    # Only active (non-expired) associations count toward a tag's total,
    # and a tag whose associations have all expired drops out entirely —
    # matching what `list`/`paths_for_tag` already do. Putting
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

  # Single-row lookup by canonical path. Returns the bookkeeping the
  # `info` command needs (timestamps + ids) without forcing callers to
  # scan `directories()` and filter — the caller already has the exact
  # path, so a direct lookup is both clearer and avoids reading every
  # row. Tags are not included here; callers compose with `tags_for`
  # and `tag_expirations` so we don't grow another GROUP_CONCAT join
  # that's only used in one place.
  record PathInfo,
    id : Int64,
    short_id : String,
    path : String,
    basename : String,
    created_at : Int64,
    last_used_at : Int64

  def find_path_info(path : String) : PathInfo?
    row = @db.query_one?(
      "SELECT id, short_id, path, basename, created_at, last_used_at " \
      "FROM directories WHERE path = ?",
      path,
      as: {Int64, String, String, String, Int64, Int64}
    )
    return unless row
    id, short_id, p, basename, created_at, last_used_at = row
    PathInfo.new(id, short_id, p, basename, created_at, last_used_at)
  end

  # Resolves a short_id prefix to matching directories. The cd
  # command uses this to support both the bare form (`cd 0dc0db9`)
  # and prefix typing (`cd 0d` if unique). Empty result = no match;
  # multiple = ambiguous. Caller decides what to do with each.
  def directories_by_short_id_prefix(prefix : String) : Array(Entry)
    pattern = "#{prefix}%"
    rows = @db.query_all(
      <<-SQL, pattern, as: {Int64, String, String, String, String?}
        SELECT d.id, d.short_id, d.path, d.basename, #{TAGS_GROUP_CONCAT_ACTIVE}
        FROM directories d
        WHERE d.short_id LIKE ? ESCAPE '\\'
        ORDER BY d.short_id
        SQL
    )
    rows.map { |row| build_entry(row) }
  end

  # Paths matching a tag (or tag-glob), sorted by recency. A tag
  # containing `*` or `?` triggers GLOB matching so `doma cd 'work*'`
  # resolves to every directory tagged `work-foo`, `work-bar`, etc.
  # Expired tag rows are filtered out — the user shouldn't navigate
  # to a path via a tag that's no longer applied.
  def paths_for_tag(tag : String) : Array(String)
    op = tag_match_clause(tag)
    @db.query_all(
      <<-SQL, tag, as: String
        SELECT DISTINCT d.path
        FROM directories d
        INNER JOIN directory_tags dt ON dt.directory_id = d.id
        INNER JOIN tags t ON t.id = dt.tag_id
        WHERE t.name #{op} ?
          AND #{NOT_EXPIRED_DT}
        ORDER BY d.last_used_at DESC, d.path ASC
        SQL
    )
  end

  # id-only narrow filter for multi-tag AND. The list command anchors
  # on the first tag (which needs full Entry hydration to render)
  # and then intersects with the id sets of each remaining tag — and
  # only the ids matter for an intersection. Skipping the GROUP_CONCAT
  # tag subquery + Entry materialization here is cheap relative to the
  # work `directories()` would otherwise do for each rest tag.
  def directory_ids_for_tag(tag : String, *, include_expired : Bool = false) : Array(Int64)
    op = tag_match_clause(tag)
    expired_pred = include_expired ? "1=1" : NOT_EXPIRED_DT
    @db.query_all(
      <<-SQL, tag, as: Int64
        SELECT DISTINCT d.id
        FROM directories d
        INNER JOIN directory_tags dt ON dt.directory_id = d.id
        INNER JOIN tags t ON t.id = dt.tag_id
        WHERE t.name #{op} ?
          AND #{expired_pred}
        SQL
    )
  end

  # Number of `directory_tags` rows whose TTL has lapsed. The list
  # command uses this to surface a "N tag(s) hidden by TTL" banner so
  # users notice when --include-expired would change the picture.
  def expired_tag_count : Int64
    @db.scalar(
      "SELECT COUNT(*) FROM directory_tags WHERE #{IS_EXPIRED}"
    ).as(Int64)
  end

  # Substring search across path, basename, and tag name. Returns
  # deduped entries sorted by path. Same single-query GROUP_CONCAT
  # shape as `directories()` so both share `build_entry`.
  #
  # When `include_expired` is true, the tag-name match branch no longer
  # filters expired rows, and the displayed tag list includes expired
  # entries — so combining `-t TAG --include-expired <query>` in the
  # list command honors the flag end-to-end.
  def search(query : String, *, include_expired : Bool = false) : Array(Entry)
    term = "%#{escape_like(query)}%"
    tag_select = include_expired ? TAGS_GROUP_CONCAT_ALL : TAGS_GROUP_CONCAT_ACTIVE
    tag_expired_pred = include_expired ? "" : " AND #{NOT_EXPIRED_DT}"
    # Two match strategies join via UNION:
    #   1. Path / basename hit — works regardless of tag expiry
    #      (a directory with all its tags expired but a matching path
    #      should still surface).
    #   2. Tag-name hit — only counts when the tag row is still
    #      active, unless --include-expired is set.
    rows = @db.query_all(
      <<-SQL, term, term, term, as: {Int64, String, String, String, String?}
        SELECT d.id, d.short_id, d.path, d.basename, #{tag_select}
        FROM directories d
        WHERE d.id IN (
          SELECT id FROM directories
            WHERE path LIKE ? ESCAPE '\\' OR basename LIKE ? ESCAPE '\\'
          UNION
          SELECT dt.directory_id FROM directory_tags dt
            INNER JOIN tags t ON t.id = dt.tag_id
            WHERE t.name LIKE ? ESCAPE '\\'#{tag_expired_pred}
        )
        ORDER BY d.path
        SQL
    )
    rows.map { |row| build_entry(row) }
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
    future_only = include_past ? "" : " AND dt.expires_at > #{NOW_EPOCH}"
    rows = @db.query_all(
      "SELECT t.name, dt.expires_at FROM directory_tags dt " \
      "INNER JOIN tags t ON t.id = dt.tag_id " \
      "WHERE dt.directory_id = ? " \
      "  AND dt.expires_at IS NOT NULL" \
      "#{future_only}",
      directory_id, as: {String, Int64}
    )
    rows.to_h
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
    rows = @db.query_all(
      "SELECT dt.directory_id, t.name, dt.expires_at FROM directory_tags dt " \
      "INNER JOIN tags t ON t.id = dt.tag_id " \
      "WHERE dt.directory_id IN (#{placeholders}) " \
      "  AND dt.expires_at IS NOT NULL" \
      "#{future_only}",
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

  # SQLite's GLOB operator supports `*` (any chars) and `?` (any one
  # char) — same syntax users already know from shell. We pick GLOB
  # over LIKE so users don't have to remember to escape `_`/`%`,
  # which are valid characters inside tag names.
  private def tag_match_clause(tag : String) : String
    tag.includes?('*') || tag.includes?('?') ? "GLOB" : "="
  end

  private def order_clause(sort : SortBy, *, prefix : String) : String
    case sort
    in SortBy::Path   then "ORDER BY #{prefix}path"
    in SortBy::Recent then "ORDER BY #{prefix}last_used_at DESC, #{prefix}path ASC"
    end
  end

  private def build_entry(row : {Int64, String, String, String, String?}) : Entry
    id, short_id, path, basename, joined = row
    tags = joined ? joined.split('\u001f').reject(&.empty?) : [] of String
    Entry.new(id, short_id, path, basename, tags)
  end

  # SQLite LIKE uses '\' as the configured escape character below. We wrap
  # any of the three LIKE meta-chars so a user query containing '%' or '_'
  # is treated literally.
  private def escape_like(raw : String) : String
    raw.gsub(/[\\%_]/) { |m| "\\#{m}" }
  end
end
