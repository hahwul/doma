require "option_parser"
require "../../db/database"
require "../../services/importer"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/runtime"
require "../../utils/validator"

module Doma::CLI
  class ImportCommand
    def run(args : Array(String))
      explicit_mode : Doma::Importer::Mode? = nil
      assume_yes = false
      dry_run = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma import <file> [--merge | --replace] [--dry-run] [--yes]"
        # Track each flag explicitly so passing both produces a hard
        # error instead of silently letting the second one win.
        p.on("--merge", "Add to existing data (default)") do
          if explicit_mode == Doma::Importer::Mode::Replace
            raise Doma::ValidationError.new("--merge and --replace are mutually exclusive")
          end
          explicit_mode = Doma::Importer::Mode::Merge
        end
        p.on("--replace", "Wipe existing data before importing") do
          if explicit_mode == Doma::Importer::Mode::Merge
            raise Doma::ValidationError.new("--merge and --replace are mutually exclusive")
          end
          explicit_mode = Doma::Importer::Mode::Replace
        end
        p.on("-y", "--yes", "Skip the --replace confirmation prompt") { assume_yes = true }
        p.on("-n", "--dry-run", "Report what would be imported without writing anything") { dry_run = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args do |before, after|
          positional.concat(before)
          positional.concat(after)
        end
      end
      parser.parse(args)

      raise Doma::ValidationError.new("input file is required") if positional.empty?
      file = Doma::Validator.canonicalize(positional.first)

      # `explicit_mode` keeps its `Mode?` type because it's assigned
      # inside the parser's blocks; the conditional unwrap below is what
      # convinces the compiler we're handing `from_file` a plain Mode.
      mode = explicit_mode.nil? ? Doma::Importer::Mode::Merge : explicit_mode.as(Doma::Importer::Mode)

      # A dry-run writes nothing, so the destructive `--replace` prompt
      # would be a lie — skip it and let the preview run freely.
      if mode == Doma::Importer::Mode::Replace && !dry_run && !assume_yes && !Doma::Runtime.assume_yes?
        unless confirm_replace
          Doma::Logger.warn "aborted"
          exit 1
        end
      end

      Doma::Database.open do |db|
        result = Doma::Importer.from_file(db, file, mode: mode, dry_run: dry_run)
        if dry_run
          verb = mode == Doma::Importer::Mode::Replace ? "replace" : "merge"
          Doma::Logger.info(
            "[dry-run] would #{verb}: #{result.imported} imported " \
            "(#{result.added} new, #{result.updated} existing), " \
            "#{result.skipped} skipped — nothing written"
          )
        elsif result.replaced
          # After a wipe every applied entry is new, so the breakdown
          # would just restate the total — keep the terse form.
          Doma::Logger.success "import replaced: #{result.imported} imported, #{result.skipped} skipped"
        else
          # Merge: spell out new vs already-present so a no-op re-import
          # (every entry already there) doesn't read as "N imported".
          Doma::Logger.success(
            "import merged: #{result.imported} imported " \
            "(#{result.added} new, #{result.updated} existing), #{result.skipped} skipped"
          )
        end
      end
    end

    private def confirm_replace : Bool
      # In a non-interactive context (cron, pipe, CI) we can't actually ask
      # the user, so we refuse rather than silently destroy data. The
      # caller is expected to opt in explicitly with --yes.
      unless STDIN.tty?
        Doma::Logger.error "--replace requires --yes when stdin is not a TTY"
        return false
      end
      STDERR.print "This will wipe the current database. Continue? [y/N] "
      STDERR.flush
      raw = STDIN.gets
      return false if raw.nil?
      raw.strip.downcase.in?({"y", "yes"})
    end
  end
end
