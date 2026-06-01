# Maintenance paths for the Database: detecting and sweeping dead paths,
# pruning expired tag associations, removing explicit id sets, and the
# shared orphan-tag cleanup that every destructive write funnels through.
class Doma::Database
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

  # Deletes an explicit set of directory rows by id, in one transaction,
  # and reports how many were actually removed. Unlike `prune_dead!`
  # (which re-stats the filesystem to decide what is missing), this
  # trusts the caller's set verbatim. `prune --gone`'s recoverable path
  # uses it so the rows it deletes are exactly the ones it snapshotted
  # to the trash: a second independent stat pass could diverge from the
  # first (e.g. a path reappearing on a remounted disk between the two),
  # leaving a trash entry for a row that was never removed.
  def remove_ids!(ids : Array(Int64)) : Int32
    return 0 if ids.empty?
    removed = 0
    @db.transaction do |tx|
      cnn = tx.connection
      placeholders = Doma::Sql.placeholders_for(ids.size)
      args = ids.map(&.as(DB::Any))
      result = cnn.exec("DELETE FROM directories WHERE id IN (#{placeholders})", args: args)
      removed = result.rows_affected.to_i
      cleanup_orphans_tx(cnn)
    end
    removed
  end

  # Drops tag rows no longer referenced by any directory. Every
  # destructive write (tag removal, path delete, move/merge, prune)
  # funnels through here so the `tags` table never accumulates
  # orphans. Private, but called from the mutation partial too — it
  # is one method on the reopened `Database` class.
  private def cleanup_orphans_tx(cnn : DB::Connection)
    cnn.exec(
      "DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM directory_tags)"
    )
  end
end
