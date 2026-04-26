require "./spec_helper"
require "db"
require "sqlite3"

# Schema migrations are silent and run at every Database.open. The
# specs below seed an explicit older-schema database with raw SQL,
# then call Database.open and verify that we end up at CURRENT_VERSION
# without losing data along the way.

private def seed_v0_db(path : String)
  # An empty file (no tables, user_version=0) — the freshest possible
  # starting state. Migrations should run all steps in order.
  raw = DB.open("sqlite3://#{path}")
  raw.close
end

private def seed_v1_db(path : String)
  raw = DB.open("sqlite3://#{path}")
  raw.exec(<<-SQL)
    CREATE TABLE directories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL UNIQUE,
      basename TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    SQL
  raw.exec(<<-SQL)
    CREATE TABLE tags (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL
    )
    SQL
  raw.exec(<<-SQL)
    CREATE TABLE directory_tags (
      directory_id INTEGER NOT NULL,
      tag_id INTEGER NOT NULL,
      PRIMARY KEY (directory_id, tag_id),
      FOREIGN KEY (directory_id) REFERENCES directories(id) ON DELETE CASCADE,
      FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
    )
    SQL
  raw.exec("INSERT INTO directories (path, basename, created_at) VALUES (?, ?, ?)",
    "/legacy/path", "path", 1700000000)
  raw.exec("INSERT INTO tags (name, created_at) VALUES (?, ?)", "legacy", 1700000000)
  raw.exec("INSERT INTO directory_tags VALUES (1, 1)")
  raw.exec("PRAGMA user_version = 1")
  raw.close
end

private def seed_v2_db(path : String)
  seed_v1_db(path)
  raw = DB.open("sqlite3://#{path}")
  raw.exec("ALTER TABLE directories ADD COLUMN last_used_at INTEGER NOT NULL DEFAULT 0")
  raw.exec("PRAGMA user_version = 2")
  raw.close
end

private def with_temp_path(&)
  dir = File.tempname("doma-mig")
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "doma.db")
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def column_names(db : Doma::Database, table : String) : Array(String)
  db.db.query_all("PRAGMA table_info(#{table})", as: {Int32, String, String, Int32, String?, Int32})
    .map { |row| row[1] }
end

describe Doma::Migrations do
  describe "from a brand-new database (v0)" do
    it "applies every step and lands at CURRENT_VERSION" do
      with_temp_path do |path|
        seed_v0_db(path)

        db = Doma::Database.open(path)
        begin
          version = db.db.scalar("PRAGMA user_version").as(Int64).to_i
          version.should eq(Doma::Migrations::CURRENT_VERSION)

          # All v3 columns must be present.
          column_names(db, "directories").should contain("short_id")
          column_names(db, "directories").should contain("last_used_at")
          column_names(db, "directory_tags").should contain("expires_at")
        ensure
          db.close
        end
      end
    end
  end

  describe "from v1 → v3" do
    it "preserves existing rows and adds new columns" do
      with_temp_path do |path|
        seed_v1_db(path)

        # Pre-condition: the seed wrote one directory + one tag.
        before = DB.open("sqlite3://#{path}")
        before.scalar("SELECT COUNT(*) FROM directories").as(Int64).should eq(1)
        before.close

        db = Doma::Database.open(path)
        begin
          db.db.scalar("PRAGMA user_version").as(Int64).to_i
            .should eq(Doma::Migrations::CURRENT_VERSION)

          # Existing data survived the migration.
          entries = db.directories(include_expired: true)
          entries.size.should eq(1)
          entries.first.path.should eq("/legacy/path")
          entries.first.tags.should eq(["legacy"])

          # short_id was backfilled — non-empty, hex-shaped.
          entries.first.short_id.matches?(/\A[0-9a-f]{7}\z/).should be_true

          # New v2 / v3 columns exist.
          column_names(db, "directories").should contain("last_used_at")
          column_names(db, "directories").should contain("short_id")
          column_names(db, "directory_tags").should contain("expires_at")
        ensure
          db.close
        end
      end
    end

    it "backfills a unique short_id per row" do
      with_temp_path do |path|
        # Seed a v1 with three directories.
        raw = DB.open("sqlite3://#{path}")
        raw.exec(<<-SQL)
          CREATE TABLE directories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            basename TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
          SQL
        raw.exec("CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT UNIQUE, created_at INTEGER)")
        raw.exec("CREATE TABLE directory_tags (directory_id INTEGER, tag_id INTEGER, PRIMARY KEY (directory_id, tag_id))")
        3.times do |i|
          raw.exec("INSERT INTO directories (path, basename, created_at) VALUES (?, ?, ?)",
            "/seed/#{i}", "#{i}", 1700000000_i64 + i)
        end
        raw.exec("PRAGMA user_version = 1")
        raw.close

        db = Doma::Database.open(path)
        begin
          ids = db.directories(include_expired: true).map(&.short_id)
          ids.size.should eq(3)
          ids.uniq!.size.should eq(3)
          ids.each(&.matches?(/\A[0-9a-f]{7}\z/).should(be_true))
        ensure
          db.close
        end
      end
    end
  end

  describe "from v2 → v3" do
    it "adds short_id + expires_at without re-running v1/v2 logic" do
      with_temp_path do |path|
        seed_v2_db(path)

        db = Doma::Database.open(path)
        begin
          db.db.scalar("PRAGMA user_version").as(Int64).to_i
            .should eq(Doma::Migrations::CURRENT_VERSION)

          # last_used_at was already there, still defaulting to 0.
          row = db.db.query_one(
            "SELECT short_id, last_used_at FROM directories WHERE id = 1",
            as: {String, Int64}
          )
          row[0].should_not be_empty
          row[1].should eq(0_i64)
        ensure
          db.close
        end
      end
    end
  end

  describe "idempotency" do
    it "running migrations twice is a no-op" do
      with_temp_path do |path|
        # First open performs all migrations.
        Doma::Database.open(path).close

        # Second open should see version == CURRENT and skip.
        before = File.size(path)
        Doma::Database.open(path).close
        after = File.size(path)

        # File can grow slightly from WAL bookkeeping; the important
        # thing is the column set didn't double up.
        db = Doma::Database.open(path)
        begin
          short_id_cols = column_names(db, "directories").count("short_id")
          short_id_cols.should eq(1)
          expires_cols = column_names(db, "directory_tags").count("expires_at")
          expires_cols.should eq(1)
        ensure
          db.close
        end
        # Ensure variables stay live so Crystal doesn't optimize away.
        (after - before).should be >= 0
      end
    end
  end
end
