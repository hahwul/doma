require "file_utils"
require "json"
require "../db/database"
require "../utils/config"
require "../utils/errors"
require "../utils/sql"

module Doma
  # Soft-delete recovery store. `rm` writes a snapshot of the entry here
  # before dropping it from sqlite; `doma trash restore` reads it back
  # and re-inserts. The format is JSONL because:
  #   - append-only writes are crash-safe (no half-written file)
  #   - a user can `cat`/`grep` it without tooling
  #   - migrations are unnecessary — older lines are still valid JSON
  module Trash
    extend self

    # Default retention. Issue #5 picked 7d as the recovery window;
    # tweakable via the constructor in case that turns out wrong.
    DEFAULT_RETENTION_SECONDS = 7_i64 * 86_400_i64

    # Per-line record. JSON keys are intentionally explicit so future
    # fields can be added without breaking older readers.
    struct Entry
      include JSON::Serializable

      property deleted_at : Int64
      property short_id : String
      property path : String
      property basename : String
      property last_used_at : Int64
      property tags : Array(String)
      # tag_name => unix epoch. Restore re-applies these so a tagged
      # `--ttl 7d` entry comes back with the original deadline (not a
      # fresh 7-day clock).
      property expirations : Hash(String, Int64)

      def initialize(@deleted_at, @short_id, @path, @basename,
                     @last_used_at, @tags, @expirations)
      end
    end

    def file_path : String
      File.join(Doma::Config.home, "trash.jsonl")
    end

    # Build a snapshot of an entry from the live database, in the shape
    # `add!` expects. Returns nil if the path isn't currently registered
    # (callers should check this before issuing the actual delete so the
    # trash row mirrors what was removed).
    def snapshot(db : Doma::Database, abs_path : String) : Entry?
      row = db.db.query_one?(
        "SELECT id, short_id, path, basename, last_used_at " \
        "FROM directories WHERE path = ?",
        abs_path, as: {Int64, String, String, String, Int64}
      )
      return unless row
      id, short_id, path, basename, last_used_at = row
      tags = db.tags_for(id)
      expirations = db.tag_expirations(id, include_past: true)
      Entry.new(
        deleted_at: Time.utc.to_unix,
        short_id: short_id,
        path: path,
        basename: basename,
        last_used_at: last_used_at,
        tags: tags,
        expirations: expirations,
      )
    end

    # Append a snapshot to the trash file. Lazy mkdir so callers that
    # never trash anything don't pay for a directory creation.
    def add!(entry : Entry)
      Doma::Config.ensure_home!
      File.open(file_path, "a") do |io|
        io.puts entry.to_json
      end
    end

    # All currently-recoverable entries (newest first). Lazy-prunes
    # anything older than `retention_seconds` so the file doesn't grow
    # unbounded — done here, on `empty`, and on `add!` so housekeeping
    # is never a separate user step.
    def entries(*, retention_seconds : Int64 = DEFAULT_RETENTION_SECONDS, prune : Bool = true) : Array(Entry)
      raw = read_all
      now = Time.utc.to_unix
      cutoff = now - retention_seconds
      kept, pruned = raw.partition { |e| e.deleted_at >= cutoff }
      rewrite!(kept) if prune && !pruned.empty?
      kept.sort_by { |e| -e.deleted_at }
    end

    # Most-recent trash entry for a canonical path, or nil if there
    # isn't one. The same path can land in trash repeatedly (rm → add →
    # rm), so we return the freshest snapshot — that's what `info`
    # surfaces to the user as "in trash". `entries` is already
    # newest-first by `deleted_at`, so a `find` here picks the right one.
    def find_by_path(path : String) : Entry?
      entries(prune: false).find { |e| e.path == path }
    end

    # Resolve a short_id (full or unique prefix) to a trash entry. The
    # CLI mirrors `rm`/`trash restore`'s prefix resolution so the same
    # 7-char id works across the suite.
    def find_by_short_id(prefix : String) : Entry?
      hits = entries(prune: false).select(&.short_id.starts_with?(prefix))
      case hits.size
      when 0 then nil
      when 1 then hits.first
      else
        list = hits.map(&.short_id).join(", ")
        raise Doma::ValidationError.new(
          "short_id prefix '#{prefix}' is ambiguous (matches: #{list})"
        )
      end
    end

    # Restore a trashed entry back into the database. Returns the
    # restored entry on success. Raises ConflictError when the path
    # already exists and `merge` is false; with `merge: true` it folds
    # the trashed tags into the live row (like `move`'s collision path).
    def restore!(db : Doma::Database, entry : Entry, *, merge : Bool = false) : Entry
      now = Time.utc.to_unix
      db.transaction do |cnn|
        # Resolve `existing` inside the transaction so the check and the
        # subsequent INSERT see the same snapshot. Doing the SELECT first
        # on `db.db` lets a concurrent `rm`/`add` race in between, leaving
        # `existing` stale — either ConflictError on a row that no longer
        # exists, or a UNIQUE violation on the INSERT branch.
        existing = cnn.query_one?(
          "SELECT id FROM directories WHERE path = ?", entry.path, as: Int64
        )

        if existing && !merge
          raise Doma::ConflictError.new(
            "path already registered: #{entry.path} (use --merge to combine tags)"
          )
        end

        directory_id : Int64 = existing || begin
          cnn.exec(
            "INSERT INTO directories (path, basename, short_id, created_at, last_used_at) " \
            "VALUES (?, ?, ?, ?, ?)",
            entry.path, entry.basename, entry.short_id, now, entry.last_used_at
          )
          cnn.scalar("SELECT id FROM directories WHERE path = ?", entry.path).as(Int64)
        end

        # Two-pass tag write to cut the per-tag round-trip cost from 3
        # statements (INSERT OR IGNORE INTO tags + SELECT id + INSERT
        # INTO directory_tags) down to ~2 amortized:
        #   pass 1) prefetch every existing tag id with one IN-list
        #           lookup; INSERT OR IGNORE only the names that
        #           actually need a new row, then re-resolve those ids
        #           in a second IN-list query
        #   pass 2) INSERT INTO directory_tags as one multi-row VALUES
        #           statement so we hit SQLite once for the whole tag
        #           set instead of N times
        unless entry.tags.empty?
          existing_ids = fetch_tag_ids(cnn, entry.tags)

          missing = entry.tags.reject { |t| existing_ids.has_key?(t) }
          unless missing.empty?
            # Single multi-row INSERT OR IGNORE so a brand-new restore
            # with N tags pays one SQL call rather than N. ON CONFLICT
            # on `tags.name` (UNIQUE) means concurrent restores remain
            # safe.
            args = [] of DB::Any
            missing.each do |t|
              args << t.as(DB::Any)
              args << now.as(DB::Any)
            end
            cnn.exec(
              "INSERT OR IGNORE INTO tags (name, created_at) VALUES " \
              "#{Doma::Sql.placeholders_for(missing.size, "(?, ?)")}",
              args: args
            )
            existing_ids.merge!(fetch_tag_ids(cnn, missing))
          end

          # Multi-row INSERT for the join table. `expirations` only
          # carries already-future TTLs from snapshot time, but a long
          # stay in the trash may have lapsed them. We still write the
          # original value — the user opted in to that deadline once,
          # and `prune_expired` will lift any that are now past as soon
          # as it runs.
          dt_args = [] of DB::Any
          entry.tags.each do |tag|
            tag_id = existing_ids[tag]
            dt_args << directory_id.as(DB::Any)
            dt_args << tag_id.as(DB::Any)
            exp = entry.expirations[tag]?
            dt_args << (exp.nil? ? nil.as(DB::Any) : exp.as(DB::Any))
          end
          cnn.exec(
            "INSERT INTO directory_tags (directory_id, tag_id, expires_at) VALUES " \
            "#{Doma::Sql.placeholders_for(entry.tags.size, "(?, ?, ?)")} " \
            "ON CONFLICT(directory_id, tag_id) DO UPDATE SET expires_at = excluded.expires_at",
            args: dt_args
          )
        end
      end

      remove_from_file!(entry)
      entry
    end

    # Permanently drop trashed entries, optionally only those older than
    # `older_seconds`. Returns the count purged.
    def empty!(*, older_seconds : Int64? = nil) : Int32
      raw = read_all
      return 0 if raw.empty?

      kept, pruned =
        if cutoff_age = older_seconds
          cutoff = Time.utc.to_unix - cutoff_age
          raw.partition { |e| e.deleted_at >= cutoff }
        else
          {[] of Entry, raw}
        end

      rewrite!(kept)
      pruned.size
    end

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    # Resolve a batch of tag names to their ids in one round-trip.
    # Returns the names that already exist; callers compare against the
    # input to decide which need an INSERT OR IGNORE first.
    private def fetch_tag_ids(cnn : DB::Connection, names : Array(String)) : Hash(String, Int64)
      return {} of String => Int64 if names.empty?
      args = names.map { |t| t.as(DB::Any) }
      cnn.query_all(
        "SELECT name, id FROM tags WHERE name IN (#{Doma::Sql.placeholders_for(names.size)})",
        args: args, as: {String, Int64}
      ).to_h
    end

    private def read_all : Array(Entry)
      path = file_path
      return [] of Entry unless File.exists?(path)
      out = [] of Entry
      File.each_line(path) do |line|
        next if line.strip.empty?
        # A truncated or hand-edited line shouldn't take down the whole
        # trash — skip and continue. We can't usefully complain to the
        # user mid-`rm`, so silently drop the malformed row.
        begin
          out << Entry.from_json(line)
        rescue JSON::ParseException
          next
        end
      end
      out
    end

    private def rewrite!(entries : Array(Entry))
      path = file_path
      if entries.empty?
        File.delete(path) if File.exists?(path)
        return
      end
      Doma::Config.ensure_home!
      tmp = "#{path}.tmp"
      File.open(tmp, "w") do |io|
        entries.each { |e| io.puts e.to_json }
      end
      File.rename(tmp, path)
    end

    private def remove_from_file!(target : Entry)
      remaining = read_all.reject do |e|
        e.deleted_at == target.deleted_at && e.short_id == target.short_id && e.path == target.path
      end
      rewrite!(remaining)
    end
  end
end
