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

    # `imported` stays the total of successfully-applied entries
    # (`added + updated`) so existing callers keep working; `added` /
    # `updated` break that total down so the user can tell a real merge
    # from a no-op re-import (every entry already present → updated, not
    # added).
    record Result,
      imported : Int32,
      skipped : Int32,
      replaced : Bool,
      added : Int32 = 0,
      updated : Int32 = 0

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
      label = source ? " (#{source})" : ""
      format = detect_format(content, source)

      case format
      in Format::Json
        begin
          Snapshot.from_json(content)
        rescue ex : JSON::ParseException | JSON::SerializableError
          raise ImportError.new("malformed snapshot#{label}: invalid JSON — #{ex.message}")
        end
      in Format::Yaml
        begin
          Snapshot.from_yaml(content)
        rescue ex : YAML::ParseException
          raise ImportError.new("malformed snapshot#{label}: invalid YAML — #{ex.message}")
        end
      end
    end

    private enum Format
      Json
      Yaml
    end

    # Prefer file extension when the source path tells us — that way
    # `bad.json` reports as JSON failure even when its body happens to
    # look YAML-shaped (e.g. plain text). Fall back to leading-character
    # sniffing for content piped in without a filename.
    private def detect_format(content : String, source : String?) : Format
      if source
        ext = File.extname(source).downcase
        return Format::Json if ext == ".json"
        return Format::Yaml if ext == ".yaml" || ext == ".yml"
      end
      stripped = content.lstrip
      stripped.starts_with?('{') || stripped.starts_with?('[') ? Format::Json : Format::Yaml
    end

    private def apply(db : Doma::Database, snapshot : Snapshot, mode : Mode) : Result
      if snapshot.version > Snapshot::SCHEMA_VERSION
        raise ImportError.new(
          "snapshot schema v#{snapshot.version} is newer than supported v#{Snapshot::SCHEMA_VERSION}"
        )
      end

      added = 0
      updated = 0
      skipped = 0
      skipped_messages = [] of String

      # Single transaction for the whole import — clear + every add — so
      # `--replace` can't half-wipe the database when a later entry fails.
      db.transaction do |cnn|
        db.clear_tx(cnn) if mode == Mode::Replace

        snapshot.entries.each do |entry|
          begin
            # Classify before writing: was this canonical path already a
            # row? The check runs on the transaction's own connection so a
            # path that appears twice in one snapshot counts as added once,
            # then updated. `add_tx` canonicalizes identically (it uses
            # `Validator.canonicalize` when `validate_path` is false), so
            # this lookup matches the row add_tx will touch.
            abs = Doma::Validator.canonicalize(entry.path)
            existed = !cnn.query_one?(
              "SELECT 1 FROM directories WHERE path = ?", abs, as: Int32
            ).nil?

            # Skip path validation: importing across machines is normal,
            # and the snapshot may legitimately reference paths that don't
            # exist on this host yet.
            #
            # `add_tx` applies a single `expires_at` to every tag in the
            # call, so when the snapshot carries per-tag TTLs (v2+) we
            # group tags by their expiry and dispatch one call per
            # group. v1 snapshots have no `expirations` map → one call,
            # all permanent, which matches the old behavior.
            #
            # An entry with an empty `tags` array is still a valid row —
            # the user explicitly registered a path with no tags. Dispatch
            # one zero-tag `add_tx` so the directory row gets created;
            # without this the importer would silently increment the
            # `imported` counter while leaving the database unchanged.
            if entry.tags.empty?
              db.add_tx(cnn, entry.path, entry.tags, validate_path: false)
            else
              ttl_map = entry.expirations || EMPTY_TTL_MAP
              grouped = Hash(Int64?, Array(String)).new { |h, k| h[k] = [] of String }
              entry.tags.each do |t|
                grouped[ttl_map[t]?] << t
              end
              grouped.each do |ttl, tag_group|
                db.add_tx(cnn, entry.path, tag_group, validate_path: false, expires_at: ttl)
              end
            end
            existed ? (updated += 1) : (added += 1)
          rescue ex : Doma::ValidationError
            skipped += 1
            skipped_messages << "import: skipped #{entry.path} (#{ex.message})"
          end
        end
      end

      # Defer warnings until after the commit so they don't appear ahead of
      # an error from the transaction itself.
      skipped_messages.each { |msg| Doma::Logger.warn msg }

      Result.new(added + updated, skipped, mode == Mode::Replace, added, updated)
    end
  end
end
