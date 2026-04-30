require "file_utils"
require "json"
require "../db/database"
require "../utils/config"
require "../utils/errors"

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

    # Resolve a short_id (full or unique prefix) to a trash entry. The
    # CLI mirrors `cd`/`rm`'s prefix resolution so `doma trash restore
    # abc12` works the same way the original `cd abc12` did.
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
      existing = db.db.query_one?(
        "SELECT id FROM directories WHERE path = ?", entry.path, as: Int64
      )

      if existing && !merge
        raise Doma::ConflictError.new(
          "path already registered: #{entry.path} (use --merge to combine tags)"
        )
      end

      now = Time.utc.to_unix
      db.transaction do |cnn|
        directory_id : Int64 = existing || begin
          cnn.exec(
            "INSERT INTO directories (path, basename, short_id, created_at, last_used_at) " \
            "VALUES (?, ?, ?, ?, ?)",
            entry.path, entry.basename, entry.short_id, now, entry.last_used_at
          )
          cnn.scalar("SELECT id FROM directories WHERE path = ?", entry.path).as(Int64)
        end

        entry.tags.each do |tag|
          cnn.exec("INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)", tag, now)
          tag_id = cnn.scalar("SELECT id FROM tags WHERE name = ?", tag).as(Int64)
          # `expirations` only carries already-future TTLs from snapshot
          # time, but a long stay in the trash may have lapsed them. We
          # still write the original value — the user opted in to that
          # deadline once, and `prune_expired` will lift any that are
          # now past as soon as it runs.
          expires_at = entry.expirations[tag]?
          cnn.exec(
            "INSERT INTO directory_tags (directory_id, tag_id, expires_at) VALUES (?, ?, ?) " \
            "ON CONFLICT(directory_id, tag_id) DO UPDATE SET expires_at = excluded.expires_at",
            directory_id, tag_id, expires_at
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
