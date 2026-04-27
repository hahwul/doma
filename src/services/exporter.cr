require "json"
require "yaml"
require "../db/database"

module Doma
  # On-disk snapshot of the doma database. Lives in its own file so the
  # exporter, importer, and tests can all share a single source of truth for
  # the schema. The `version` field is what protects forward-compat — older
  # binaries refuse to load snapshots they can't fully understand.
  class Snapshot
    include JSON::Serializable
    include YAML::Serializable

    # v2 added the optional `expirations` field on Entry so TTL info
    # survives export/import round-trips. v1 snapshots are still
    # accepted: missing `expirations` simply means every tag is
    # permanent, which matches v1 semantics.
    SCHEMA_VERSION = 2

    property version : Int32
    property generated_at : Int64?
    property entries : Array(Entry)

    def initialize(@entries : Array(Entry), @version : Int32 = SCHEMA_VERSION, @generated_at : Int64? = Time.utc.to_unix)
    end

    class Entry
      include JSON::Serializable
      include YAML::Serializable

      property path : String
      property basename : String?
      property tags : Array(String) = [] of String
      # tag_name => expires_at (unix epoch seconds). Only emitted when
      # at least one tag has a TTL — keeps snapshots from common
      # permanent-only setups visually identical to v1.
      @[JSON::Field(emit_null: false)]
      @[YAML::Field(emit_null: false)]
      property expirations : Hash(String, Int64)? = nil

      def initialize(@path : String, @tags : Array(String), @basename : String? = nil, @expirations : Hash(String, Int64)? = nil)
      end
    end
  end

  module Exporter
    extend self

    enum Format
      Json
      Yaml
    end

    def build(db : Doma::Database) : Snapshot
      entries = db.directories.map do |e|
        ttl_map = db.tag_expirations(e.id)
        Snapshot::Entry.new(e.path, e.tags, e.basename, ttl_map.empty? ? nil : ttl_map)
      end
      Snapshot.new(entries)
    end

    def write(db : Doma::Database, format : Format, io : IO)
      snapshot = build(db)
      case format
      in Format::Json
        snapshot.to_json(io)
        io << '\n'
      in Format::Yaml
        snapshot.to_yaml(io)
      end
    end
  end
end
