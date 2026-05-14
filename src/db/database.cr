require "db"
require "sqlite3"
require "../models/entry"
require "../utils/config"
require "../utils/errors"
require "../utils/sql"
require "../utils/suggester"
require "../utils/validator"
require "./migrations"

module Doma
  # Thin wrapper over the SQLite handle. All multi-statement writes run inside
  # a transaction so a partial failure can never leave dangling tag rows or
  # half-applied imports.
  class Database
    getter db : DB::Database
    getter path : String

    def self.open(path : String? = nil) : Database
      target = path || Doma::Config.db_path
      Doma::Config.ensure_home! if target == Doma::Config.db_path

      # Catch obvious misconfigurations up front so the user gets a
      # clean ConfigError instead of an empty-message
      # `DB::ConnectionRefused` from the SQLite layer.
      if Dir.exists?(target)
        raise Doma::ConfigError.new("DOMA_DB points at a directory, not a file: #{target}")
      end

      # Doma is a read/write tool — every command path can mutate state
      # (even `cd`, which bumps `last_used_at`). On a non-writable file
      # SQLite happily opens the connection and then segfaults during
      # statement finalization once a write is attempted, so we surface
      # the failure here while we still have a clean stack.
      if File.exists?(target)
        unless File::Info.writable?(target)
          raise Doma::ConfigError.new("database file is not writable: #{target}")
        end
      else
        parent = File.dirname(target)
        if Dir.exists?(parent) && !File::Info.writable?(parent)
          raise Doma::ConfigError.new("cannot create database in non-writable directory: #{parent}")
        end
      end

      # DSN-encoded pragmas apply on every pool connection (setting them
      # once via `db.exec PRAGMA …` only affects whichever connection ran
      # the exec). The trio matters:
      #   - foreign_keys=on   →  CASCADE actually fires on directory delete
      #   - journal_mode=wal  →  readers don't block the writer, and the
      #                          writer doesn't block readers — important
      #                          when the user has doma open in several
      #                          shells at once
      #   - busy_timeout      →  on lock contention, sleep-retry for up to
      #                          5s instead of failing immediately
      #
      # Retry the initial open: when several `doma` processes hit a
      # brand-new database simultaneously, the per-connection
      # `PRAGMA journal_mode=wal` runs *before* `busy_timeout` takes
      # effect, so a contended WAL bootstrap surfaces as
      # `DB::ConnectionRefused` instead of silently waiting. Once the
      # first process has set up the WAL files, subsequent opens are
      # fine — a short backoff loop is enough to ride that out.
      raw = open_with_retry(target)
      Migrations.run(raw)
      new(raw, target)
    end

    private OPEN_MAX_ATTEMPTS = 25
    private OPEN_BACKOFF      = 100.milliseconds

    private def self.open_with_retry(target : String) : DB::Database
      attempt = 0
      loop do
        attempt += 1
        begin
          return DB.open("sqlite3://#{target}?foreign_keys=on&journal_mode=wal&busy_timeout=5000")
        rescue ex : DB::ConnectionRefused
          raise wrap_open_error(target, ex) if attempt >= OPEN_MAX_ATTEMPTS
          sleep OPEN_BACKOFF
        rescue ex
          raise wrap_open_error(target, ex)
        end
      end
    end

    private def self.wrap_open_error(target : String, ex : Exception) : Doma::Error
      message = ex.message.presence || ex.class.name
      Doma::Error.new("cannot open database (#{target}): #{message}")
    end

    def initialize(@db : DB::Database, @path : String)
    end

    def close
      @db.close
    end

    # ---------- Mutations ----------

    # Adds a path with the given tags. The path must already exist on disk
    # unless `validate_path` is false (used by the importer for cross-machine
    # snapshots). Tags are validated and de-duplicated.
    #
    # `expires_at` (unix epoch seconds) sets a per-tag TTL — passed as nil
    # the tags are permanent. Re-tagging *refreshes* the TTL: doing
    # `add . -t bookmark --ttl 7d` again resets the clock.
    def add(path : String, tags : Array(String), *, validate_path : Bool = true, expires_at : Int64? = nil) : Int64
      directory_id = 0_i64
      @db.transaction do |tx|
        directory_id = add_tx(tx.connection, path, tags,
          validate_path: validate_path, expires_at: expires_at)
      end
      directory_id
    end

    # Same as `add`, but operates on an already-open transaction. Used by
    # the importer so an entire import (clear + many inserts) commits
    # atomically — a torn import never replaces existing rows with garbage.
    def add_tx(cnn : DB::Connection, path : String, tags : Array(String),
               *, validate_path : Bool = true, expires_at : Int64? = nil) : Int64
      abs = validate_path ? Validator.path!(path) : Validator.canonicalize(path)
      clean_tags = Validator.tags!(tags)
      basename = File.basename(abs)
      now = Time.utc.to_unix

      # short_id is generated only on insert (the ON CONFLICT clause
      # leaves it untouched). That makes the value stable for the
      # lifetime of the directory — once you cd via `crystal:abc1234`,
      # that handle keeps working until the row is removed.
      short_id = Migrations.generate_short_id(@db)
      cnn.exec(
        "INSERT INTO directories (path, basename, short_id, created_at) VALUES (?, ?, ?, ?) " \
        "ON CONFLICT(path) DO UPDATE SET basename = excluded.basename",
        abs, basename, short_id, now
      )
      directory_id = cnn.scalar("SELECT id FROM directories WHERE path = ?", abs).as(Int64)

      clean_tags.each do |tag|
        cnn.exec("INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)", tag, now)
        tag_id = cnn.scalar("SELECT id FROM tags WHERE name = ?", tag).as(Int64)
        # ON CONFLICT DO UPDATE so re-tagging refreshes expires_at —
        # absent --ttl on a re-tag, the row reverts to permanent (NULL).
        # That mirrors what the user is asking for: "the latest add is
        # the source of truth for this tag."
        cnn.exec(
          "INSERT INTO directory_tags (directory_id, tag_id, expires_at) VALUES (?, ?, ?) " \
          "ON CONFLICT(directory_id, tag_id) DO UPDATE SET expires_at = excluded.expires_at",
          directory_id, tag_id, expires_at
        )
      end

      directory_id
    end

    # Run a block inside a single transaction. Used by the importer to
    # group clear + many adds together. The block receives the connection
    # so it can call `*_tx` variants.
    def transaction(&)
      @db.transaction do |tx|
        yield tx.connection
      end
    end

    # Outcome of `remove_tags`. Three states because the CLI surfaces
    # different messages for each:
    #   :not_registered — the path isn't tracked at all
    #   :no_match       — path exists but none of the requested tags were on it
    #   :removed        — at least one tag association was actually deleted
    enum RemoveTagsResult
      NotRegistered
      NoMatch
      Removed
    end

    def remove_tags(path : String, tags : Array(String)) : RemoveTagsResult
      abs = Validator.canonicalize(path)
      result = RemoveTagsResult::NotRegistered
      @db.transaction do |tx|
        cnn = tx.connection
        directory_id = cnn.query_one?("SELECT id FROM directories WHERE path = ?", abs, as: Int64)
        next unless directory_id
        result = RemoveTagsResult::NoMatch

        tags.each do |tag|
          tag_id = cnn.query_one?("SELECT id FROM tags WHERE name = ?", tag, as: Int64)
          next unless tag_id
          deleted = cnn.exec(
            "DELETE FROM directory_tags WHERE directory_id = ? AND tag_id = ?",
            directory_id, tag_id
          ).rows_affected
          result = RemoveTagsResult::Removed if deleted > 0
        end
        cleanup_orphans_tx(cnn)
      end
      result
    end

    def remove_path(path : String) : Bool
      abs = Validator.canonicalize(path)
      affected = 0_i64
      @db.transaction do |tx|
        cnn = tx.connection
        affected = cnn.exec("DELETE FROM directories WHERE path = ?", abs).rows_affected
        cleanup_orphans_tx(cnn)
      end
      affected > 0
    end

    # Updates a registered directory's path while keeping its tags. If the
    # destination is already registered, the two entries are merged: tags
    # from `old_path` are added to the destination row and the source row
    # is dropped. Returns one of `:moved`, `:merged`, or raises if either
    # side validates badly.
    def move_path(old_path : String, new_path : String, *, validate_path : Bool = true) : Symbol
      old_abs = Validator.canonicalize(old_path)
      new_abs = validate_path ? Validator.path!(new_path) : Validator.canonicalize(new_path)
      return :noop if old_abs == new_abs

      result : Symbol = :moved
      @db.transaction do |tx|
        cnn = tx.connection
        old_id = cnn.query_one?("SELECT id FROM directories WHERE path = ?", old_abs, as: Int64)
        unless old_id
          known = cnn.query_all("SELECT path FROM directories", as: String)
          raise NotFoundError.new(
            "path not registered: #{old_abs}",
            hint: Suggester.hint_for(old_abs, known)
          )
        end

        existing_id = cnn.query_one?("SELECT id FROM directories WHERE path = ?", new_abs, as: Int64)
        if existing_id
          # Merge: copy any tags missing from the destination, then drop
          # the source. INSERT OR IGNORE collapses duplicates so a tag
          # present on both sides stays as one row.
          cnn.exec(
            "INSERT OR IGNORE INTO directory_tags (directory_id, tag_id) " \
            "SELECT ?, tag_id FROM directory_tags WHERE directory_id = ?",
            existing_id, old_id
          )
          cnn.exec("DELETE FROM directories WHERE id = ?", old_id)
          result = :merged
        else
          cnn.exec(
            "UPDATE directories SET path = ?, basename = ? WHERE id = ?",
            new_abs, File.basename(new_abs), old_id
          )
        end
        cleanup_orphans_tx(cnn)
      end
      result
    end

    # ---------- Maintenance ----------

    # Returns entries whose registered path no longer exists on disk.
    # `Dir.exists?` rather than `File.exists?` because we explicitly
    # store directories — a path that's been replaced by a regular file
    # is just as broken for our purposes.
    #
    # We pull only the columns the prune/list-check display actually
    # needs (id, short_id, path, basename) and pass an empty tag list
    # to `Entry.new`. The previous implementation went through the full
    # `directories()` query whose GROUP_CONCAT subquery hydrates every
    # active tag for every directory — wasted work since the only
    # caller (`prune --gone`) prints just the path. At 10k rows the
    # cheap variant is roughly 2× faster, and the saved work scales
    # linearly with tag fanout.
    def dead_paths : Array(Entry)
      rows = @db.query_all(
        "SELECT id, short_id, path, basename FROM directories",
        as: {Int64, String, String, String}
      )
      rows.compact_map do |row|
        id, short_id, path, basename = row
        Dir.exists?(path) ? nil : Entry.new(id, short_id, path, basename, [] of String)
      end
    end

    # (path, tag) pair that was pruned. Surfaced by `prune --expired` so
    # the user sees what disappeared instead of just a count.
    record ExpiredAssoc, path : String, tag : String

    # Removes every directory_tags row whose TTL has elapsed. Returns
    # the (path, tag) pairs that were dropped. The size of the returned
    # array is what previous callers used as the count, so call sites
    # asking "how many did we prune?" can still use `result.size`. Empty
    # tags from `tags` table get garbage-collected too via the orphan
    # cleanup.
    def prune_expired! : Array(ExpiredAssoc)
      removed = [] of ExpiredAssoc
      @db.transaction do |tx|
        cnn = tx.connection
        # Capture the (path, tag) pairs *before* the DELETE so we can
        # report what was swept. Deferring this to after the DELETE
        # would lose them; the JOIN is cheap because the WHERE filters
        # to already-expired rows only.
        rows = cnn.query_all(
          <<-SQL, as: {String, String}
            SELECT d.path, t.name
            FROM directory_tags dt
            INNER JOIN directories d ON d.id = dt.directory_id
            INNER JOIN tags t ON t.id = dt.tag_id
            WHERE #{IS_EXPIRED_DT}
            ORDER BY d.path, t.name
            SQL
        )
        rows.each { |row| removed << ExpiredAssoc.new(row[0], row[1]) }

        cnn.exec(
          "DELETE FROM directory_tags WHERE #{IS_EXPIRED}"
        )
        cleanup_orphans_tx(cnn)
      end
      removed
    end

    # Removes every directory whose path no longer exists on disk.
    # Single transaction so a partial failure can't leave half-pruned
    # state. Returns the number of rows actually deleted.
    #
    # Two-step: collect the dead ids first (one stat per row, no DB
    # writes), then drop them all in one `DELETE … WHERE id IN (…)`.
    # The previous implementation called `DELETE … WHERE id = ?` row
    # by row, which on a high-mortality cleanup (user moved their
    # ~/Projects out from under doma) added up to N round trips inside
    # one transaction. Batching keeps the same atomicity guarantee
    # without per-row overhead.
    def prune_dead! : Int32
      removed = 0
      @db.transaction do |tx|
        cnn = tx.connection
        rows = cnn.query_all("SELECT id, path FROM directories", as: {Int64, String})
        dead_ids = rows.compact_map { |row| Dir.exists?(row[1]) ? nil : row[0] }

        unless dead_ids.empty?
          placeholders = Doma::Sql.placeholders_for(dead_ids.size)
          args = dead_ids.map { |id| id.as(DB::Any) }
          result = cnn.exec("DELETE FROM directories WHERE id IN (#{placeholders})", args: args)
          removed = result.rows_affected.to_i
        end
        cleanup_orphans_tx(cnn)
      end
      removed
    end

    # Wipes every row. Used by `import --replace`.
    def clear!
      @db.transaction do |tx|
        clear_tx(tx.connection)
      end
    end

    # Same as `clear!`, scoped to an existing transaction.
    def clear_tx(cnn : DB::Connection)
      cnn.exec("DELETE FROM directory_tags")
      cnn.exec("DELETE FROM directories")
      cnn.exec("DELETE FROM tags")
    end

    # ---------- Queries ----------

    enum SortBy
      Path
      Recent # most-recently-used first
    end

    # SQLite's GLOB operator supports `*` (any chars) and `?` (any one
    # char) — same syntax users already know from shell. We pick GLOB
    # over LIKE so users don't have to remember to escape `_`/`%`,
    # which are valid characters inside tag names.
    private def tag_match_clause(tag : String) : String
      tag.includes?('*') || tag.includes?('?') ? "GLOB" : "="
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

    # ------------------------------------------------------------------
    # Shared SQL fragments. Centralized so a future schema change to
    # the TTL representation (precision shift, NULL semantics, column
    # rename) lands in one place. Each predicate is parenthesized so it
    # composes safely after `AND`/`OR` in a longer WHERE.
    # ------------------------------------------------------------------

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

    private def build_entry(row : {Int64, String, String, String, String?}) : Entry
      id, short_id, path, basename, joined = row
      tags = joined ? joined.split('\u001f').reject(&.empty?) : [] of String
      Entry.new(id, short_id, path, basename, tags)
    end

    private def order_clause(sort : SortBy, *, prefix : String) : String
      case sort
      in SortBy::Path   then "ORDER BY #{prefix}path"
      in SortBy::Recent then "ORDER BY #{prefix}last_used_at DESC, #{prefix}path ASC"
      end
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
      @db.query_all(
        <<-SQL, as: {String, Int64}
          SELECT t.name, COUNT(dt.directory_id) AS cnt
          FROM tags t
          LEFT JOIN directory_tags dt ON dt.tag_id = t.id
          GROUP BY t.id
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

    # Stamps a directory as just-used. Idempotent on missing paths
    # (silently no-ops) so callers don't need to gate the bump on
    # existence — `cd` still wants to print whatever was selected even
    # if the underlying row got pruned in a parallel session.
    def bump_used!(path : String)
      abs = Validator.canonicalize(path)
      @db.exec(
        "UPDATE directories SET last_used_at = ? WHERE path = ?",
        Time.utc.to_unix, abs
      )
    end

    # Renames a tag. If `new_name` already exists, the two are merged:
    # every `directory_tags` row pointing at the old tag is re-pointed
    # at the new one, carrying its `expires_at` along. When a path
    # already had both tags, the merge keeps whichever lifetime is
    # *longer* (NULL/permanent beats any TTL; among two TTLs the later
    # epoch wins) — picking the more permissive duration matches how
    # `add` treats a tagless re-add as "make permanent." Runs in one
    # transaction so a failure can't leave a half-merged tag behind.
    def rename_tag(old_name : String, new_name : String) : Symbol
      cleaned = Validator.tag!(new_name)
      return :noop if cleaned == old_name

      old_id = @db.query_one?("SELECT id FROM tags WHERE name = ?", old_name, as: Int64)
      unless old_id
        raise NotFoundError.new(
          "tag not found: #{old_name}",
          hint: Suggester.hint_for(old_name, tag_names)
        )
      end

      result = :renamed
      @db.transaction do |tx|
        cnn = tx.connection
        existing = cnn.query_one?("SELECT id FROM tags WHERE name = ?", cleaned, as: Int64)
        if existing
          # Re-point every old-tag row at the new tag, carrying the
          # original `expires_at` so a TTL'd source row doesn't get
          # silently promoted to permanent. On per-path collision
          # (path already had both tags), MAX-with-NULL-as-permanent
          # picks the more permissive lifetime: NULL wins over any
          # epoch, otherwise the larger epoch wins.
          cnn.exec(
            "INSERT INTO directory_tags (directory_id, tag_id, expires_at) " \
            "SELECT directory_id, ?, expires_at FROM directory_tags WHERE tag_id = ? " \
            "ON CONFLICT(directory_id, tag_id) DO UPDATE SET expires_at = " \
            "  CASE " \
            "    WHEN excluded.expires_at IS NULL OR directory_tags.expires_at IS NULL THEN NULL " \
            "    ELSE MAX(excluded.expires_at, directory_tags.expires_at) " \
            "  END",
            existing, old_id
          )
          cnn.exec("DELETE FROM directory_tags WHERE tag_id = ?", old_id)
          cnn.exec("DELETE FROM tags WHERE id = ?", old_id)
          result = :merged
        else
          cnn.exec("UPDATE tags SET name = ? WHERE id = ?", cleaned, old_id)
        end
      end
      result
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
      total_tags = @db.scalar("SELECT COUNT(*) FROM tags").as(Int64)

      top = @db.query_all(
        <<-SQL, top_n, as: {String, Int64}
          SELECT t.name, COUNT(dt.directory_id) AS cnt
          FROM tags t
          LEFT JOIN directory_tags dt ON dt.tag_id = t.id
          GROUP BY t.id
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

    # SQLite LIKE uses '\' as the configured escape character below. We wrap
    # any of the three LIKE meta-chars so a user query containing '%' or '_'
    # is treated literally.
    private def escape_like(raw : String) : String
      raw.gsub(/[\\%_]/) { |m| "\\#{m}" }
    end

    private def cleanup_orphans_tx(cnn : DB::Connection)
      cnn.exec(
        "DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM directory_tags)"
      )
    end
  end
end
