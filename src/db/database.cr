require "db"
require "sqlite3"
require "../models/entry"
require "../utils/config"
require "../utils/errors"
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
      raw = DB.open("sqlite3://#{target}?foreign_keys=on&journal_mode=wal&busy_timeout=5000")
      Migrations.run(raw)
      new(raw, target)
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
    def add(path : String, tags : Array(String), *, validate_path : Bool = true) : Int64
      directory_id = 0_i64
      @db.transaction do |tx|
        directory_id = add_tx(tx.connection, path, tags, validate_path: validate_path)
      end
      directory_id
    end

    # Same as `add`, but operates on an already-open transaction. Used by
    # the importer so an entire import (clear + many inserts) commits
    # atomically — a torn import never replaces existing rows with garbage.
    def add_tx(cnn : DB::Connection, path : String, tags : Array(String), *, validate_path : Bool = true) : Int64
      abs = validate_path ? Validator.path!(path) : Validator.canonicalize(path)
      clean_tags = Validator.tags!(tags)
      basename = File.basename(abs)
      now = Time.utc.to_unix

      cnn.exec(
        "INSERT INTO directories (path, basename, created_at) VALUES (?, ?, ?) " \
        "ON CONFLICT(path) DO UPDATE SET basename = excluded.basename",
        abs, basename, now
      )
      directory_id = cnn.scalar("SELECT id FROM directories WHERE path = ?", abs).as(Int64)

      clean_tags.each do |tag|
        cnn.exec("INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)", tag, now)
        tag_id = cnn.scalar("SELECT id FROM tags WHERE name = ?", tag).as(Int64)
        cnn.exec(
          "INSERT OR IGNORE INTO directory_tags (directory_id, tag_id) VALUES (?, ?)",
          directory_id, tag_id
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

    def remove_tags(path : String, tags : Array(String)) : Bool
      abs = Validator.canonicalize(path)
      removed_any = false
      @db.transaction do |tx|
        cnn = tx.connection
        directory_id = cnn.query_one?("SELECT id FROM directories WHERE path = ?", abs, as: Int64)
        next unless directory_id
        removed_any = true

        tags.each do |tag|
          tag_id = cnn.query_one?("SELECT id FROM tags WHERE name = ?", tag, as: Int64)
          next unless tag_id
          cnn.exec(
            "DELETE FROM directory_tags WHERE directory_id = ? AND tag_id = ?",
            directory_id, tag_id
          )
        end
        cleanup_orphans_tx(cnn)
      end
      removed_any
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

    def directories(tag : String? = nil) : Array(Entry)
      rows = if tag
               @db.query_all(
                 <<-SQL, tag, as: {Int64, String, String}
                   SELECT d.id, d.path, d.basename
                   FROM directories d
                   INNER JOIN directory_tags dt ON dt.directory_id = d.id
                   INNER JOIN tags t ON t.id = dt.tag_id
                   WHERE t.name = ?
                   ORDER BY d.path
                   SQL
               )
             else
               @db.query_all(
                 "SELECT id, path, basename FROM directories ORDER BY path",
                 as: {Int64, String, String}
               )
             end

      rows.map do |row|
        id, path, basename = row
        Entry.new(id, path, basename, tags_for(id))
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

    def paths_for_tag(tag : String) : Array(String)
      @db.query_all(
        <<-SQL, tag, as: String
          SELECT d.path
          FROM directories d
          INNER JOIN directory_tags dt ON dt.directory_id = d.id
          INNER JOIN tags t ON t.id = dt.tag_id
          WHERE t.name = ?
          ORDER BY d.path
          SQL
      )
    end

    # Renames a tag. If `new_name` already exists, the two are merged: every
    # `directory_tags` row pointing at the old tag is re-pointed at the new
    # one (with INSERT OR IGNORE so duplicates collapse), then the old tag
    # row is dropped. Runs in one transaction so a failure can't leave a
    # half-merged tag behind.
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
          cnn.exec(
            "INSERT OR IGNORE INTO directory_tags (directory_id, tag_id) " \
            "SELECT directory_id, ? FROM directory_tags WHERE tag_id = ?",
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

    # Substring search across path, basename, and tag name. Returns deduped
    # entries sorted by path. A single SQL query joins through tags and
    # collects them per directory via GROUP_CONCAT — this used to do an
    # N+1 (one extra SELECT per matched directory for its tag list).
    def search(query : String) : Array(Entry)
      term = "%#{escape_like(query)}%"
      rows = @db.query_all(
        <<-SQL, term, term, term, as: {Int64, String, String, String?}
          SELECT d.id,
                 d.path,
                 d.basename,
                 (
                   SELECT GROUP_CONCAT(tag_name, X'1f')
                   FROM (
                     SELECT t2.name AS tag_name
                     FROM tags t2
                     INNER JOIN directory_tags dt2 ON dt2.tag_id = t2.id
                     WHERE dt2.directory_id = d.id
                     ORDER BY t2.name
                   )
                 ) AS joined_tags
          FROM directories d
          LEFT JOIN directory_tags dt ON dt.directory_id = d.id
          LEFT JOIN tags t ON t.id = dt.tag_id
          WHERE d.path     LIKE ? ESCAPE '\\'
             OR d.basename LIKE ? ESCAPE '\\'
             OR t.name     LIKE ? ESCAPE '\\'
          GROUP BY d.id
          ORDER BY d.path
          SQL
      )
      rows.map do |row|
        id, path, basename, joined = row
        # Use the unit-separator (0x1f) as the GROUP_CONCAT delimiter so
        # the split is unambiguous even if a tag ever contained a comma —
        # belt and suspenders against future schema changes.
        tags = joined ? joined.split('').reject(&.empty?) : [] of String
        Entry.new(id, path, basename, tags)
      end
    end

    record Stats,
      total_directories : Int64,
      total_tags : Int64,
      top_tags : Array(TagSummary),
      recent : Array(NamedTuple(path: String, created_at: Int64))

    def stats(top_n : Int32 = 10, recent_n : Int32 = 5) : Stats
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

      Stats.new(total_dirs, total_tags, top, recent)
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
