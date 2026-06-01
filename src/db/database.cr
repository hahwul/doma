require "db"
require "sqlite3"
require "../models/entry"
require "../utils/config"
require "../utils/errors"
require "../utils/sql"
require "../utils/suggester"
require "../utils/validator"
require "./migrations"

module Doma
  # Thin wrapper over the SQLite handle. All multi-statement writes run inside
  # a transaction so a partial failure can never leave dangling tag rows or
  # half-applied imports.
  #
  # The class is split across `db/database/` for readability — connection
  # lifecycle lives here; the rest is grouped by concern into reopened-class
  # partials that all merge back into this one type:
  #   sql_fragments — shared SQL string constants (TTL predicates, joins)
  #   mutations     — add / remove / move / rename / clear
  #   maintenance   — dead-path detection, prune, orphan cleanup
  #   queries       — list / search / stats and the row-mapping helpers
  class Database
    getter db : DB::Database
    getter path : String

    def self.open(path : String? = nil) : Database
      target = path || Doma::Config.db_path
      Doma::Config.ensure_home! if target == Doma::Config.db_path

      # Catch obvious misconfigurations up front so the user gets a
      # clean ConfigError instead of an empty-message
      # `DB::ConnectionRefused` from the SQLite layer.
      if Dir.exists?(target)
        raise Doma::ConfigError.new("DOMA_DB points at a directory, not a file: #{target}")
      end

      # Doma is a read/write tool — every command path can mutate state
      # (even `cd`, which bumps `last_used_at`). On a non-writable file
      # SQLite happily opens the connection and then segfaults during
      # statement finalization once a write is attempted, so we surface
      # the failure here while we still have a clean stack.
      if File.exists?(target)
        unless File::Info.writable?(target)
          raise Doma::ConfigError.new("database file is not writable: #{target}")
        end
      else
        parent = File.dirname(target)
        if Dir.exists?(parent) && !File::Info.writable?(parent)
          raise Doma::ConfigError.new("cannot create database in non-writable directory: #{parent}")
        end
      end

      # DSN-encoded pragmas apply on every pool connection (setting them
      # once via `db.exec PRAGMA …` only affects whichever connection ran
      # the exec). The trio matters:
      #   - foreign_keys=on   →  CASCADE actually fires on directory delete
      #   - journal_mode=wal  →  readers don't block the writer, and the
      #                          writer doesn't block readers — important
      #                          when the user has doma open in several
      #                          shells at once
      #   - busy_timeout      →  on lock contention, sleep-retry for up to
      #                          5s instead of failing immediately
      #
      # Retry the initial open: when several `doma` processes hit a
      # brand-new database simultaneously, the per-connection
      # `PRAGMA journal_mode=wal` runs *before* `busy_timeout` takes
      # effect, so a contended WAL bootstrap surfaces as
      # `DB::ConnectionRefused` instead of silently waiting. Once the
      # first process has set up the WAL files, subsequent opens are
      # fine — a short backoff loop is enough to ride that out.
      raw = open_with_retry(target)
      Migrations.run(raw)
      new(raw, target)
    end

    private OPEN_MAX_ATTEMPTS = 25
    private OPEN_BACKOFF      = 100.milliseconds

    private def self.open_with_retry(target : String) : DB::Database
      attempt = 0
      loop do
        attempt += 1
        begin
          return DB.open("sqlite3://#{target}?foreign_keys=on&journal_mode=wal&busy_timeout=5000")
        rescue ex : DB::ConnectionRefused
          raise wrap_open_error(target, ex) if attempt >= OPEN_MAX_ATTEMPTS
          sleep OPEN_BACKOFF
        rescue ex
          raise wrap_open_error(target, ex)
        end
      end
    end

    private def self.wrap_open_error(target : String, ex : Exception) : Doma::Error
      message = ex.message.presence || ex.class.name
      Doma::Error.new("cannot open database (#{target}): #{message}")
    end

    def initialize(@db : DB::Database, @path : String)
    end

    def close
      @db.close
    end
  end
end

require "./database/sql_fragments"
require "./database/mutations"
require "./database/maintenance"
require "./database/queries"
