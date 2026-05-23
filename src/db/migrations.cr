require "../utils/errors"

module Doma
  # Schema migrations keyed off SQLite's built-in `PRAGMA user_version`.
  # New databases run every step from 0 → CURRENT in order; existing
  # databases pick up only the steps they're behind on.
  #
  # The cost of running ALTER on a table that the previous step just
  # created (fresh DB case) is negligible — keeping each migration
  # additive lets us reason about every step independently.
  module Migrations
    CURRENT_VERSION = 3

    # Width of the random hex `short_id` we generate for each directory.
    # 7 chars = 16M values; birthday collision near 16k dirs, well above
    # any realistic doma corpus.
    SHORT_ID_BYTES = 4
    SHORT_ID_CHARS = 7

    def self.run(db : DB::Database)
      # Two `doma` processes opening a fresh database at the same time
      # used to race here: each read `user_version = 0`, both tried to
      # `ALTER TABLE … ADD COLUMN`, and the loser crashed with
      # "duplicate column name". Pinning the whole sequence to one
      # connection and entering with `BEGIN IMMEDIATE` acquires the
      # SQLite writer lock up front, so a concurrent invocation either
      # waits (busy_timeout) and then sees the bumped user_version, or
      # fails fast with a clear lock error rather than a corrupt
      # half-applied schema.
      db.using_connection do |cnn|
        cnn.exec("BEGIN IMMEDIATE")
        begin
          version = cnn.scalar("PRAGMA user_version").as(Int64).to_i
          # A user_version higher than what this binary knows about means
          # the DB was last opened by a newer doma. Silently continuing
          # would let stale queries hit columns/constraints we don't know
          # about and fail with a confusing SQLite error. Surface a clear
          # message instead; the outer `rescue` handles the ROLLBACK.
          if version > CURRENT_VERSION
            raise Doma::Error.new(
              "database schema is v#{version}, but this doma binary only " \
              "understands up to v#{CURRENT_VERSION}. Upgrade doma."
            )
          end
          if version < CURRENT_VERSION
            apply_v1(cnn) if version < 1
            apply_v2(cnn) if version < 2
            apply_v3(cnn) if version < 3
            cnn.exec("PRAGMA user_version = #{CURRENT_VERSION}")
          end
          cnn.exec("COMMIT")
        rescue ex
          begin
            cnn.exec("ROLLBACK")
          rescue
            # If the transaction was already aborted by SQLite (e.g. a
            # statement error auto-rolled it back), ROLLBACK errors —
            # don't shadow the original failure.
          end
          raise ex
        end
      end
    end

    # Generates a unique 7-hex short_id, retrying on the (rare) collision.
    def self.generate_short_id(db : DB::Database) : String
      loop do
        candidate = Random.new.random_bytes(SHORT_ID_BYTES).hexstring[0, SHORT_ID_CHARS]
        existing = db.scalar(
          "SELECT COUNT(*) FROM directories WHERE short_id = ?", candidate
        ).as(Int64)
        return candidate if existing == 0
      end
    end

    # Connection-scoped variant used during migration backfill, where
    # the surrounding `BEGIN IMMEDIATE` means a `DB::Database`-level
    # SELECT on a different pool connection wouldn't see in-flight
    # inserts.
    private def self.generate_short_id(cnn : DB::Connection) : String
      loop do
        candidate = Random.new.random_bytes(SHORT_ID_BYTES).hexstring[0, SHORT_ID_CHARS]
        existing = cnn.scalar(
          "SELECT COUNT(*) FROM directories WHERE short_id = ?", candidate
        ).as(Int64)
        return candidate if existing == 0
      end
    end

    # v1: original three-table schema.
    private def self.apply_v1(cnn : DB::Connection)
      cnn.exec(
        <<-SQL
          CREATE TABLE IF NOT EXISTS directories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            basename TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
          SQL
      )
      cnn.exec(
        <<-SQL
          CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL
          )
          SQL
      )
      cnn.exec(
        <<-SQL
          CREATE TABLE IF NOT EXISTS directory_tags (
            directory_id INTEGER NOT NULL,
            tag_id INTEGER NOT NULL,
            PRIMARY KEY (directory_id, tag_id),
            FOREIGN KEY (directory_id) REFERENCES directories(id) ON DELETE CASCADE,
            FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
          )
          SQL
      )
      cnn.exec("CREATE INDEX IF NOT EXISTS idx_directory_tags_tag ON directory_tags(tag_id)")
      cnn.exec("CREATE INDEX IF NOT EXISTS idx_directory_tags_dir ON directory_tags(directory_id)")
    end

    # v2: track when each directory was last picked. `0` (never used) is
    # the default so existing rows don't need a backfill — they sort to
    # the bottom of recency-ordered listings until first use.
    private def self.apply_v2(cnn : DB::Connection)
      return if column_exists?(cnn, "directories", "last_used_at")
      cnn.exec("ALTER TABLE directories ADD COLUMN last_used_at INTEGER NOT NULL DEFAULT 0")
      cnn.exec("CREATE INDEX IF NOT EXISTS idx_directories_last_used ON directories(last_used_at)")
    end

    # v3: short_id (commit-hash-style addressing) on directories, and
    # expires_at (NULL = forever) on directory_tags so a single tag can
    # be either long-lived or temporary.
    #
    # SQLite ALTER TABLE can't add a NOT NULL UNIQUE column directly, so
    # we add nullable, backfill, then enforce uniqueness via a separate
    # index. The Crystal layer never inserts NULL on new rows, which
    # keeps the column effectively NOT NULL going forward.
    private def self.apply_v3(cnn : DB::Connection)
      unless column_exists?(cnn, "directories", "short_id")
        cnn.exec("ALTER TABLE directories ADD COLUMN short_id TEXT")
        backfill_short_ids(cnn)
        cnn.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_directories_short_id ON directories(short_id)")
      end

      unless column_exists?(cnn, "directory_tags", "expires_at")
        cnn.exec("ALTER TABLE directory_tags ADD COLUMN expires_at INTEGER")
        # Indexed because every read filters on it.
        cnn.exec("CREATE INDEX IF NOT EXISTS idx_directory_tags_expires ON directory_tags(expires_at)")
      end
    end

    private def self.backfill_short_ids(cnn : DB::Connection)
      ids = cnn.query_all("SELECT id FROM directories WHERE short_id IS NULL", as: Int64)
      ids.each do |id|
        cnn.exec("UPDATE directories SET short_id = ? WHERE id = ?", generate_short_id(cnn), id)
      end
    end

    private def self.column_exists?(cnn : DB::Connection, table : String, column : String) : Bool
      cnn.query_all("PRAGMA table_info(#{table})", as: {Int32, String, String, Int32, String?, Int32})
        .any? { |row| row[1] == column }
    end
  end
end
