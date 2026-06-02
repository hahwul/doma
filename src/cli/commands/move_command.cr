require "option_parser"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/suggester"
require "../../utils/validator"

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
        # Pre-checks ordered to give actionable errors:
        #   (1) Is the source registered? — without this, an unregistered
        #       <old> with a non-existent <new> would surface "not a
        #       directory: <new>", pointing the user at the wrong arg.
        #   (2) Does <new> validate (or is --allow-missing set)? —
        #       canonicalize without disk-existence so we can attach an
        #       --allow-missing hint when the path is simply not on this
        #       machine yet (the common cross-host case).
        # `db.move_path` re-runs the source lookup inside its transaction,
        # so the (1) check is duplicate work but trivially cheap and worth
        # it for the better error path.
        # Canonicalize both up front: used for the pre-checks below and,
        # crucially, for the success message — `add`/`list` always show
        # the canonical stored path, and echoing the raw args here (e.g.
        # `/tmp/...` instead of `/private/tmp/...`, or a trailing slash)
        # made move look like it touched a different path than it stored.
        old_abs = Doma::Validator.canonicalize(old_path)
        new_abs = Doma::Validator.canonicalize(new_path)
        unless db.find_path_info(old_abs)
          raise Doma::NotFoundError.new(
            "path not registered: #{old_abs}",
            hint: Doma::Suggester.hint_for(old_abs, db.directories.map(&.path))
          )
        end

        unless allow_missing
          # Bypass `Validator.path!`'s built-in "not a directory" message
          # so we can attach the --allow-missing hint. Non-existence on
          # the destination is the *normal* shape for "I haven't moved
          # the directory on disk yet" and "I'm syncing from another
          # host" — the previous bare error pushed users to make a
          # placeholder dir or hand-edit the database.
          unless Dir.exists?(new_abs)
            raise Doma::ValidationError.new(
              "not a directory: #{new_abs}",
              hint: "pass --allow-missing if the destination isn't on this machine yet " \
                    "(e.g. cross-host snapshot, or you haven't done the disk move yet)"
            )
          end
        end

        case db.move_path(old_path, new_path, validate_path: !allow_missing)
        when :noop
          Doma::Logger.info "no change (#{old_abs} == #{new_abs})"
        when :moved
          Doma::Logger.success "moved #{old_abs} -> #{new_abs}"
        when :merged
          Doma::Logger.success "merged #{old_abs} into existing #{new_abs}"
        end
      ensure
        db.close
      end
    end
  end
end
