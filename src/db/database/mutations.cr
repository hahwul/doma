# Write paths for the Database: registering paths/tags, removing tag
# associations, moving paths, renaming tags, and wholesale clears. Every
# multi-statement write runs inside a transaction so a partial failure
# can never leave dangling tag rows or half-applied edits.
class Doma::Database
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

    # Tag writes batched into three statements regardless of tag count,
    # instead of three round trips *per* tag. On a bulk import (many
    # entries, each re-running add_tx) that's the difference between
    # ~3N and ~3 queries per directory. `clean_tags` is already
    # de-duplicated by `Validator.tags!`, so no two rows below collide on
    # the same conflict target within one statement.
    unless clean_tags.empty?
      # 1. Create any missing tag rows in one multi-row INSERT OR IGNORE.
      #    Existing tags are skipped, preserving their original created_at.
      tag_rows = Doma::Sql.placeholders_for(clean_tags.size, "(?, ?)")
      tag_args = clean_tags.flat_map { |tag| [tag.as(DB::Any), now.as(DB::Any)] }
      cnn.exec("INSERT OR IGNORE INTO tags (name, created_at) VALUES #{tag_rows}", args: tag_args)

      # 2. Map every name → id in one IN-list SELECT.
      name_placeholders = Doma::Sql.placeholders_for(clean_tags.size)
      id_by_name = {} of String => Int64
      cnn.query_all(
        "SELECT name, id FROM tags WHERE name IN (#{name_placeholders})",
        args: clean_tags.map(&.as(DB::Any)), as: {String, Int64}
      ).each { |row| id_by_name[row[0]] = row[1] }

      # 3. Upsert all associations in one multi-row statement. Each row
      #    keeps the per-row ON CONFLICT semantics: re-tagging refreshes
      #    expires_at — absent --ttl on a re-tag it reverts to permanent
      #    (NULL), so "the latest add is the source of truth for this tag."
      assoc_rows = Doma::Sql.placeholders_for(clean_tags.size, "(?, ?, ?)")
      assoc_args = clean_tags.flat_map do |tag|
        [directory_id.as(DB::Any), id_by_name[tag].as(DB::Any), expires_at.as(DB::Any)]
      end
      cnn.exec(
        "INSERT INTO directory_tags (directory_id, tag_id, expires_at) VALUES #{assoc_rows} " \
        "ON CONFLICT(directory_id, tag_id) DO UPDATE SET expires_at = excluded.expires_at",
        args: assoc_args
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
end
