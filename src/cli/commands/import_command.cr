require "option_parser"
require "../../db/database"
require "../../services/importer"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/validator"

module Doma::CLI
  class ImportCommand
    def run(args : Array(String))
      mode = Doma::Importer::Mode::Merge
      assume_yes = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma import <file> [--merge | --replace] [--yes]"
        p.on("--merge", "Add to existing data (default)") { mode = Doma::Importer::Mode::Merge }
        p.on("--replace", "Wipe existing data before importing") { mode = Doma::Importer::Mode::Replace }
        p.on("-y", "--yes", "Skip the --replace confirmation prompt") { assume_yes = true }
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

      if mode == Doma::Importer::Mode::Replace && !assume_yes
        unless confirm_replace
          Doma::Logger.warn "aborted"
          exit 1
        end
      end

      db = Doma::Database.open
      begin
        result = Doma::Importer.from_file(db, file, mode: mode)
        kind = result.replaced ? "replaced" : "merged"
        Doma::Logger.success "import #{kind}: #{result.imported} imported, #{result.skipped} skipped"
      ensure
        db.close
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
