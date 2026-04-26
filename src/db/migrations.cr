module Doma
  module Migrations
    SCHEMA = [
      <<-SQL,
        CREATE TABLE IF NOT EXISTS directories (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT NOT NULL UNIQUE,
          basename TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
        SQL
      <<-SQL,
        CREATE TABLE IF NOT EXISTS tags (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL
        )
        SQL
      <<-SQL,
        CREATE TABLE IF NOT EXISTS directory_tags (
          directory_id INTEGER NOT NULL,
          tag_id INTEGER NOT NULL,
          PRIMARY KEY (directory_id, tag_id),
          FOREIGN KEY (directory_id) REFERENCES directories(id) ON DELETE CASCADE,
          FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
        )
        SQL
      "CREATE INDEX IF NOT EXISTS idx_directory_tags_tag ON directory_tags(tag_id)",
      "CREATE INDEX IF NOT EXISTS idx_directory_tags_dir ON directory_tags(directory_id)",
    ]

    def self.run(db : DB::Database)
      # foreign_keys is enabled per-connection via the DSN
      # (`?foreign_keys=on`); setting it here would only affect this
      # specific exec call, not other pool connections.
      SCHEMA.each { |stmt| db.exec(stmt) }
    end
  end
end
