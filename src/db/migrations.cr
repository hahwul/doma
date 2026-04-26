module Doma
  # Schema migrations keyed off SQLite's built-in `PRAGMA user_version`.
  # New databases run every step from 0 → CURRENT in order; existing
  # databases pick up only the steps they're behind on.
  #
  # The cost of running ALTER on a table that the previous step just
  # created (fresh DB case) is negligible — keeping each migration
  # additive lets us reason about every step independently.
  module Migrations
    CURRENT_VERSION = 2

    def self.run(db : DB::Database)
      version = db.scalar("PRAGMA user_version").as(Int64).to_i
      return if version >= CURRENT_VERSION

      apply_v1(db) if version < 1
      apply_v2(db) if version < 2

      db.exec("PRAGMA user_version = #{CURRENT_VERSION}")
    end

    # v1: original three-table schema.
    private def self.apply_v1(db : DB::Database)
      db.exec(
        <<-SQL
          CREATE TABLE IF NOT EXISTS directories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            basename TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
          SQL
      )
      db.exec(
        <<-SQL
          CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL
          )
          SQL
      )
      db.exec(
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
      db.exec("CREATE INDEX IF NOT EXISTS idx_directory_tags_tag ON directory_tags(tag_id)")
      db.exec("CREATE INDEX IF NOT EXISTS idx_directory_tags_dir ON directory_tags(directory_id)")
    end

    # v2: track when each directory was last picked. `0` (never used) is
    # the default so existing rows don't need a backfill — they sort to
    # the bottom of recency-ordered listings until first use.
    private def self.apply_v2(db : DB::Database)
      return if column_exists?(db, "directories", "last_used_at")
      db.exec("ALTER TABLE directories ADD COLUMN last_used_at INTEGER NOT NULL DEFAULT 0")
      db.exec("CREATE INDEX IF NOT EXISTS idx_directories_last_used ON directories(last_used_at)")
    end

    private def self.column_exists?(db : DB::Database, table : String, column : String) : Bool
      db.query_all("PRAGMA table_info(#{table})", as: {Int32, String, String, Int32, String?, Int32})
        .any? { |row| row[1] == column }
    end
  end
end
