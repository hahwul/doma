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
          if t.strip.empty?
            raise Doma::ValidationError.new("tag is empty (-t got an empty value)")
          end
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
      missing = 0
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
              # Same shape as `info <path>` for an unregistered path:
              # ✗ marker + "to register it" hint + NotFoundError exit
              # code (3). Previously this warned with `!` and exited 0,
              # so a script doing `doma rm "$x" && something` couldn't
              # tell whether anything was actually removed.
              missing += 1
              Doma::Logger.error "not registered: #{raw}"
              STDERR.puts "  #{not_registered_hint(db, raw)}"
            end
          else
            case db.remove_tags(path, cleaned_tags)
            in Doma::Database::RemoveTagsResult::Removed
              Doma::Logger.success "untagged #{Doma::Validator.canonicalize(path)} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NoMatch
              Doma::Logger.warn "no matching tag(s) on #{Doma::Validator.canonicalize(path)} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NotRegistered
              missing += 1
              Doma::Logger.error "not registered: #{raw}"
              STDERR.puts "  #{not_registered_hint(db, raw)}"
            end
          end
        end
      ensure
        db.close
      end
      # NotFoundError exit code (3) — matches `doma info <unknown>` and
      # makes `doma rm <unknown> && next` fail loudly. Successful removes
      # in the same batch are still committed (partial-success batch
      # semantics, same as `add`).
      exit 3 if missing > 0
    end

    private def resolve_target(db : Doma::Database, raw : String) : String
      return raw unless Doma::ShortIdResolver.looks_like?(raw)
      Doma::ShortIdResolver.resolve(db, raw) || raw
    end

    # `not registered` follow-up. The default hint points the user at
    # `doma add <raw>`, but two common shapes need a different steer:
    #   - short_id already in the trash → `doma trash restore`
    #   - the raw matches a known *tag name* → the user almost
    #     certainly meant "untag this from a path" (rm takes -t TAG)
    #     or "rename/merge the tag", not "register a new path called
    #     `alpha`". Without this branch, `doma rm alpha` left the user
    #     staring at "to register it, run: doma add alpha", which is
    #     the opposite of what they wanted.
    private def not_registered_hint(db : Doma::Database, raw : String) : String
      if Doma::ShortIdResolver.looks_like?(raw)
        if entry = Doma::Trash.find_by_short_id(raw.downcase)
          return "in trash (#{entry.path}). " \
                 "Restore: doma trash restore #{entry.short_id[0..6]}"
        end
      end

      if !raw.includes?('/') && !raw.includes?('.') && db.tag_names.includes?(raw)
        return "looks like a tag name. To untag a path: " \
               "doma rm <path> -t #{raw} (or `doma rename #{raw} <new>` to relabel)"
      end

      "to register it, run: doma add #{raw}"
    end
  end
end
