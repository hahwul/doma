require "option_parser"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"

module Doma::CLI
  # Updates a registered directory's path. Tags carry over. If the new
  # path is already in the database, the entries merge (the union of tags
  # ends up on the new row, the old row is dropped).
  #
  # Use `--allow-missing` when moving to a path that doesn't exist on this
  # machine — useful when doma travels with you across hosts via export
  # but absolute paths differ.
  class MoveCommand
    def run(args : Array(String))
      allow_missing = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma move <old-path> <new-path> [--allow-missing]"
        p.on("--allow-missing", "Skip the existence check on <new-path>") { allow_missing = true }
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Updates a registered directory's path. Tags carry over."
          STDOUT.puts ""
          STDOUT.puts "If <new-path> is already registered, the two entries are"
          STDOUT.puts "merged: tags from <old-path> are added to the destination row"
          STDOUT.puts "(union — no duplicates) and the source row is dropped."
          STDOUT.puts ""
          STDOUT.puts "Use --allow-missing for paths not on this machine yet"
          STDOUT.puts "(e.g. when a snapshot from another host references a path"
          STDOUT.puts "that hasn't been synced down yet)."
          STDOUT.puts ""
          STDOUT.puts "Runs in a single transaction."
          exit 0
        end
        p.unknown_args do |before, after|
          positional.concat(before)
          positional.concat(after)
        end
      end
      parser.parse(args)

      if positional.size != 2
        raise Doma::ValidationError.new("expected exactly two arguments: <old-path> <new-path>")
      end

      old_path, new_path = positional[0], positional[1]
      db = Doma::Database.open
      begin
        case db.move_path(old_path, new_path, validate_path: !allow_missing)
        when :noop
          Doma::Logger.info "no change (#{old_path} == #{new_path})"
        when :moved
          Doma::Logger.success "moved #{old_path} -> #{new_path}"
        when :merged
          Doma::Logger.success "merged #{old_path} into existing #{new_path}"
        end
      ensure
        db.close
      end
    end
  end
end
