require "json"
require "yaml"
require "../db/database"
require "../utils/errors"
require "../utils/logger"
require "../utils/validator"
require "./exporter"

module Doma
  # Loads a snapshot back into the database. The whole operation runs inside
  # a single SQLite transaction so a torn import — a malformed entry, a
  # crashed process, anything — can never replace existing rows with
  # garbage. The user gets either the full new state or the original.
  module Importer
    extend self

    record Result, imported : Int32, skipped : Int32, replaced : Bool

    # Reused across all v1 entries so we don't allocate a fresh empty
    # hash per row.
    private EMPTY_TTL_MAP = {} of String => Int64

    enum Mode
      Merge
      Replace
    end

    def from_file(db : Doma::Database, path : String, *, mode : Mode = Mode::Merge) : Result
      raise ImportError.new("import file not found: #{path}") unless File.file?(path)
      content = File.read(path)
      raise ImportError.new("import file is empty: #{path}") if content.strip.empty?
      snapshot = parse(content, path)
      apply(db, snapshot, mode)
    end

    def parse(content : String, source : String? = nil) : Snapshot
      stripped = content.lstrip
      # Pick the parser deterministically rather than try-fallback so the
      # error the user sees points at the right format.
      if stripped.starts_with?('{') || stripped.starts_with?('[')
        Snapshot.from_json(content)
      else
        Snapshot.from_yaml(content)
      end
    rescue ex : JSON::ParseException | YAML::ParseException | JSON::SerializableError
      label = source ? " (#{source})" : ""
      raise ImportError.new("malformed snapshot#{label}: #{ex.message}")
    end

    private def apply(db : Doma::Database, snapshot : Snapshot, mode : Mode) : Result
      if snapshot.version > Snapshot::SCHEMA_VERSION
        raise ImportError.new(
          "snapshot schema v#{snapshot.version} is newer than supported v#{Snapshot::SCHEMA_VERSION}"
        )
      end

      imported = 0
      skipped = 0
      skipped_messages = [] of String

      # Single transaction for the whole import — clear + every add — so
      # `--replace` can't half-wipe the database when a later entry fails.
      db.transaction do |cnn|
        db.clear_tx(cnn) if mode == Mode::Replace

        snapshot.entries.each do |entry|
          begin
            # Skip path validation: importing across machines is normal,
            # and the snapshot may legitimately reference paths that don't
            # exist on this host yet.
            #
            # `add_tx` applies a single `expires_at` to every tag in the
            # call, so when the snapshot carries per-tag TTLs (v2+) we
            # group tags by their expiry and dispatch one call per
            # group. v1 snapshots have no `expirations` map → one call,
            # all permanent, which matches the old behavior.
            ttl_map = entry.expirations || EMPTY_TTL_MAP
            grouped = Hash(Int64?, Array(String)).new { |h, k| h[k] = [] of String }
            entry.tags.each do |t|
              grouped[ttl_map[t]?] << t
            end
            grouped.each do |ttl, tag_group|
              db.add_tx(cnn, entry.path, tag_group, validate_path: false, expires_at: ttl)
            end
            imported += 1
          rescue ex : Doma::ValidationError
            skipped += 1
            skipped_messages << "import: skipped #{entry.path} (#{ex.message})"
          end
        end
      end

      # Defer warnings until after the commit so they don't appear ahead of
      # an error from the transaction itself.
      skipped_messages.each { |msg| Doma::Logger.warn msg }

      Result.new(imported, skipped, mode == Mode::Replace)
    end
  end
end
