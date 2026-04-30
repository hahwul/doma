require "option_parser"
require "../../db/database"
require "../../services/trash"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/short_id_resolver"
require "../../utils/validator"

module Doma::CLI
  class RmCommand
    def run(args : Array(String))
      tags = [] of String
      hard = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma rm <path> [<path> ...] [-t TAG ...] [--hard]\n" \
                   "  (bulk cleanup: doma prune --gone | --expired)"
        p.on("-t TAG", "--tag=TAG", "Remove this tag (repeatable, comma-separated allowed)") do |t|
          t.split(',').each { |x| tags << x.strip unless x.strip.empty? }
        end
        p.on("--hard", "Skip the trash; delete permanently") { hard = true }
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

      raise Doma::ValidationError.new("path is required (use `doma prune --gone | --expired` for bulk cleanup)") if positional.empty?

      # Validate up front so a misspelled or invalid tag name fails fast
      # with a clear error, instead of silently no-op'ing inside
      # `remove_tags` (where a non-existent tag name simply matches no
      # rows). Mirrors `add_command`'s validation step.
      cleaned_tags = tags.empty? ? tags : Doma::Validator.tags!(tags)

      db = Doma::Database.open
      begin
        positional.each do |raw|
          # Accept the same `list`-printed short_id that `cd` does. Only
          # falls back when the token isn't shaped like a path (no `/`,
          # no `.`, no `~`) so a relative dir named `abc123` keeps its
          # path interpretation.
          path = resolve_target(db, raw)

          if cleaned_tags.empty?
            abs = Doma::Validator.canonicalize(path)
            # Snapshot first so a soft-delete can restore the row
            # exactly. `--hard` skips the snapshot; bulk cleanup paths
            # (`doma prune --gone | --expired`) skip it on their own.
            entry = hard ? nil : Doma::Trash.snapshot(db, abs)
            if db.remove_path(path)
              if hard
                Doma::Logger.success "removed #{abs} (permanent)"
              elsif entry
                Doma::Trash.add!(entry)
                Doma::Logger.success "trashed #{abs} (recover with `doma trash restore #{entry.short_id[0..6]}`)"
              else
                Doma::Logger.success "removed #{abs}"
              end
            else
              Doma::Logger.warn "not registered: #{raw}"
            end
          else
            case db.remove_tags(path, cleaned_tags)
            in Doma::Database::RemoveTagsResult::Removed
              Doma::Logger.success "untagged #{Doma::Validator.canonicalize(path)} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NoMatch
              Doma::Logger.warn "no matching tag(s) on #{Doma::Validator.canonicalize(path)} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NotRegistered
              Doma::Logger.warn "not registered: #{raw}"
            end
          end
        end
      ensure
        db.close
      end
    end

    private def resolve_target(db : Doma::Database, raw : String) : String
      return raw if raw.includes?('/') || raw.includes?('.') || raw.includes?('~')
      return raw unless raw.matches?(/\A[0-9a-fA-F]{4,16}\z/)
      Doma::ShortIdResolver.resolve(db, raw) || raw
    end
  end
end
