require "file_utils"
require "json"
require "../db/database"
require "../utils/config"
require "../utils/errors"
require "../utils/logger"
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

    # Default retention. Issue #5 picked 7d as the recovery window.
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
      # nil for entries trashed before this field existed; restore then
      # falls back to "now".
      property created_at : Int64?

      def initialize(@deleted_at, @short_id, @path, @basename,
                     @last_used_at, @tags, @expirations, @created_at = nil)
      end

      # 7-char display form of the short id — what `trash list` prints
      # and what restore hints reference.
      def display_id : String
        short_id[0..6]
      end
    end

    # Canonical "it's recoverable" hint attached to errors by add/rm/
    # info when the input matches a trashed entry. One format so the
    # restore incantation can't drift between commands.
    def restore_hint(entry : Entry) : String
      "in trash (#{entry.path}). Restore: doma trash restore #{entry.display_id}"
    end

    def file_path : String
      File.join(Doma::Config.home, "trash.jsonl")
    end

    # Build a snapshot of an entry from the live database, in the shape
    # `add!` expects. Returns nil if the path isn't currently registered
    # (callers should check this before issuing the actual delete so the
    # trash row mirrors what was removed).
    def snapshot(db : Doma::Database, abs_path : String) : Entry?
      info = db.find_entry(abs_path)
      return unless info
      tags = info.tags
      expirations = db.tag_expirations(info.id, include_past: true)
      Entry.new(
        deleted_at: Time.utc.to_unix,
        short_id: info.short_id,
        path: info.path,
        basename: info.basename,
        last_used_at: info.last_used_at,
        tags: tags,
        expirations: expirations,
        created_at: info.created_at,
      )
    end

    # Append snapshots to the trash file after applying retention.
    def add!(entry : Entry | Array(Entry), *, prune : Bool = true)
      additions = entry.is_a?(Entry) ? [entry] : entry
      return if additions.empty?
      with_lock do
        recoverable_entries(prune: true) if prune
        File.open(file_path, "a") do |io|
          additions.each { |addition| io.puts addition.to_json }
        end
      end
    end

    # All currently-recoverable entries (newest first). Lazy-prunes
    # anything older than the retention window so the file doesn't grow
    # unbounded — done here, on `empty`, and on `add!` so housekeeping
    # is never a separate user step.
    def entries(*, prune : Bool = true) : Array(Entry)
      with_lock(read_only: !prune) do
        # Newest first. `deleted_at` has 1-second granularity, so two
        # deletions in the same second tie; the file is written
        # chronologically, so reversing first and relying on `sort_by!`
        # being stable puts the later append (the more recent deletion)
        # first — "undo the latest" (bare `trash restore`) depends on it.
        recoverable_entries(prune).reverse.sort_by! { |e| -e.deleted_at }
      end
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

    # Restore a trashed entry back into the database. Returns true when
    # the tags were merged into an already-registered row, false on a
    # fresh insert. Raises ConflictError when the path already exists
    # and `merge` is false; with `merge: true` it folds the trashed tags
    # into the live row (like `move`'s collision path).
    def restore!(db : Doma::Database, entry : Entry, *, merge : Bool = false) : Bool
      with_lock do
        now = Time.utc.to_unix
        merged = false
        db.transaction do |cnn|
          # Resolve `existing` inside the transaction: `db.transaction`
          # takes the write lock up front (`BEGIN IMMEDIATE`, see
          # database.cr), so no other writer can slip in between this
          # SELECT and the INSERT below. `UNIQUE(path)` stays as the
          # backstop.
          existing = cnn.query_one?(
            "SELECT id FROM directories WHERE path = ?", entry.path, as: Int64
          )

          if existing && !merge
            raise Doma::ConflictError.new(
              "path already registered: #{entry.path} (use --merge to combine tags)"
            )
          end

          merged = !existing.nil?
          directory_id : Int64 = existing || begin
            cnn.exec(
              "INSERT INTO directories (path, basename, short_id, created_at, last_used_at) " \
              "VALUES (?, ?, ?, ?, ?)",
              entry.path, entry.basename, entry.short_id, entry.created_at || now, entry.last_used_at
            )
            cnn.scalar("SELECT id FROM directories WHERE path = ?", entry.path).as(Int64)
          end

          # Two multi-row statements for the whole tag set: INSERT OR
          # IGNORE every tag name (UNIQUE on `tags.name` keeps concurrent
          # restores safe), resolve the ids in one IN-list lookup, then
          # one INSERT for the join table.
          #
          # For a fresh restore (no live row) the join insert simply
          # re-applies the snapshot's TTLs — the user opted in to that
          # deadline once, and `prune_expired` lifts any now lapsed. For a
          # `--merge` restore onto an existing live row the tag may already
          # be present, so the conflict resolves to DO NOTHING: the *live*
          # binding's TTL wins. Clobbering it with `excluded.expires_at`
          # could replay a long-stale snapshot deadline onto a live tag —
          # e.g. expire a tag the user has since made permanent. This
          # matches `move_path`'s merge, which likewise keeps the
          # destination's existing binding.
          unless entry.tags.empty?
            cnn.exec(
              "INSERT OR IGNORE INTO tags (name, created_at) VALUES " \
              "#{Doma::Sql.placeholders_for(entry.tags.size, "(?, ?)")}",
              args: entry.tags.flat_map { |t| [t, now] of DB::Any }
            )
            ids = fetch_tag_ids(cnn, entry.tags)
            cnn.exec(
              "INSERT INTO directory_tags (directory_id, tag_id, expires_at) VALUES " \
              "#{Doma::Sql.placeholders_for(entry.tags.size, "(?, ?, ?)")} " \
              "ON CONFLICT(directory_id, tag_id) DO NOTHING",
              args: entry.tags.flat_map { |t| [directory_id, ids[t], entry.expirations[t]?] of DB::Any }
            )
          end
        end

        remove_from_file!(entry)
        merged
      end
    end

    # Permanently drop trashed entries, optionally only those older than
    # `older_seconds`, or exactly the `only` set (what the user was shown
    # and confirmed — anything trashed after that survives). Returns the
    # count purged.
    def empty!(*, older_seconds : Int64? = nil, only : Array(Entry)? = nil) : Int32
      with_lock do
        raw = read_all
        return 0 if raw.empty?

        kept, pruned =
          if targets = only
            remaining = targets.dup
            raw.partition do |e|
              i = remaining.index(e)
              remaining.delete_at(i) if i
              i.nil?
            end
          elsif cutoff_age = older_seconds
            cutoff = Time.utc.to_unix - cutoff_age
            raw.partition { |e| e.deleted_at >= cutoff }
          else
            {[] of Entry, raw}
          end

        rewrite!(kept)
        pruned.size
      end
    end

    # Drops one entry — used to undo an `add!` whose row delete then failed.
    def discard!(entry : Entry)
      with_lock { remove_from_file!(entry) }
    end

    # `read_only` callers (pure lookups) fall back to an unlocked read
    # when the lock can't be created (read-only DOMA_HOME); writers get a
    # clean ConfigError instead of a raw File::Error "internal error".
    private def with_lock(*, read_only : Bool = false, &)
      Doma::Config.ensure_home!
      lock_path = File.join(Doma::Config.home, "trash.lock")
      lock_file = begin
        File.open(lock_path, "w")
      rescue ex : File::Error
        return yield if read_only
        raise Doma::ConfigError.new("cannot use trash in #{Doma::Config.home}: #{ex.message}")
      end
      begin
        lock_file.flock_exclusive
        yield
      ensure
        lock_file.close
      end
    end

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    private def recoverable_entries(prune : Bool) : Array(Entry)
      raw = read_all
      cutoff = Time.utc.to_unix - DEFAULT_RETENTION_SECONDS
      kept = raw.select { |e| e.deleted_at >= cutoff }
      rewrite!(kept) if prune && kept.size != raw.size
      kept
    end

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
        # user mid-`rm`, so drop the malformed row with only a debug
        # note. (Note the next lazy prune rewrites the file from the
        # parsed set, which erases the bad line permanently — the debug
        # line is the one trace it leaves.)
        begin
          out << Entry.from_json(line)
        rescue JSON::Error
          Doma::Logger.debug "trash: skipping malformed line in #{path}"
          next
        end
      end
      out
    end

    private def rewrite!(entries : Array(Entry))
      path = file_path
      if entries.empty?
        # `File.delete?` returns false (no raise) when another concurrent
        # prune already cleared the trash file out from under us.
        File.delete?(path)
        return
      end
      Doma::Config.ensure_home!
      tmp = "#{path}.tmp"
      File.open(tmp, "w") do |io|
        entries.each { |e| io.puts e.to_json }
      end
      File.rename(tmp, path)
    end

    # Removes at most one matching line: two `rm`s of the same path in
    # the same second write identical lines, and the loser's `discard!`
    # must not take the winner's snapshot with it.
    private def remove_from_file!(target : Entry)
      remaining = read_all
      i = remaining.rindex do |e|
        e.deleted_at == target.deleted_at && e.short_id == target.short_id && e.path == target.path
      end
      return unless i
      remaining.delete_at(i)
      rewrite!(remaining)
    end
  end
end
