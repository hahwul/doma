require "option_parser"
require "../../db/database"
require "../../services/trash"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/runtime"
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
          Doma::Validator.split_tag_flag!(t).each { |part| tags << part }
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

      # `--hard` skips the trash entirely — typing it at a terminal is
      # explicit enough consent (same convention as `rm -f`), but an
      # unattended invocation (cron, a pipe, a wrapper script) has no
      # other way to signal consent, so refuse rather than silently
      # deleting something permanently. Same rule as `trash empty`.
      if hard && Doma::Runtime.non_interactive_without_consent?
        Doma::Logger.error "--hard requires --yes (or DOMA_YES=1) when not attached to a terminal (stdin/stdout)"
        exit 1
      end

      missing = 0
      failures = 0
      prune_trash = true
      Doma::Database.open do |db|
        # Validate up front so an invalid tag name fails fast with a
        # clear error. A name already stored is exempt: older versions
        # accepted names today's creation rules reject (`work/`), and rm
        # must still be able to drop them.
        known = tags.empty? ? [] of String : db.tag_names
        cleaned_tags = tags.uniq.map { |t| known.includes?(t) ? t : Doma::Validator.tag!(t) }

        positional.each do |raw|
          # Accept the same `list`-printed short_id that `cd` does. Only
          # falls back when the token isn't shaped like a path (no `/`,
          # no `.`, no `~`) so a relative dir named `abc123` keeps its
          # path interpretation.
          path = resolve_target(db, raw)

          abs = db.row_path(path)
          if cleaned_tags.empty?
            # Snapshot first so a soft-delete can restore the row
            # exactly. `--hard` skips the snapshot; bulk cleanup paths
            # (`doma prune --gone | --expired`) skip it on their own.
            # Write the trash entry *before* the delete: if the trash
            # write fails the row must survive, otherwise a soft `rm`
            # silently becomes a hard one.
            entry = hard ? nil : Doma::Trash.snapshot(db, abs)
            if entry
              Doma::Trash.add!(entry, prune: prune_trash)
              prune_trash = false
            end
            removed = begin
              db.remove_path(path)
            rescue ex
              entry.try { |e| Doma::Trash.discard!(e) }
              raise ex
            end
            # Lost a race with another `rm`: drop our now-orphan entry.
            entry.try { |e| Doma::Trash.discard!(e) } unless removed
            if removed
              if hard
                Doma::Logger.success "removed #{abs} (permanent)"
              elsif entry
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
            on_path = db.find_entry(abs).try(&.tags) || [] of String
            case db.remove_tags(path, cleaned_tags)
            in Doma::Database::RemoveTagsResult::Removed
              absent = cleaned_tags - on_path
              note = absent.empty? ? "" : "; not on path: #{absent.join(", ")}"
              Doma::Logger.success "untagged #{abs} (#{(cleaned_tags & on_path).join(", ")}#{note})"
            in Doma::Database::RemoveTagsResult::NoMatch
              # None of the requested tags were on this path. Treat like
              # `not registered`: nothing was actually changed, so exit
              # non-zero (matches `&& next` script semantics). Partial
              # success — at least one tag removed — still returns Removed.
              missing += 1
              Doma::Logger.error "no matching tag(s) on #{abs} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NotRegistered
              missing += 1
              Doma::Logger.error "not registered: #{raw}"
              STDERR.puts "  #{not_registered_hint(db, raw)}"
            end
          end
        rescue ex : Doma::ValidationError
          # One bad item (ambiguous short_id prefix, unexpandable path)
          # must not skip the rest of the batch.
          failures += 1
          Doma::Logger.error ex.message || "invalid input: #{raw}"
          if hint = ex.hint
            STDERR.puts "  #{hint}"
          end
        end
      end
      # NotFoundError exit code (3) — matches `doma info <unknown>` and
      # makes `doma rm <unknown> && next` fail loudly. Successful removes
      # in the same batch are still committed (partial-success batch
      # semantics, same as `add`). A validation failure outranks a miss
      # (exit 2), same as `add`.
      exit 2 if failures > 0
      exit 3 if missing > 0
    end

    private def resolve_target(db : Doma::Database, raw : String) : String
      return raw if File.exists?(raw)
      return raw unless Doma::ShortIdResolver.looks_like?(raw)
      # A registered hex-named dir that's gone from disk is still that
      # row — don't let its name resolve as another entry's short_id.
      return raw if registered_path?(db, raw)
      Doma::ShortIdResolver.resolve(db, raw) || raw
    end

    private def registered_path?(db : Doma::Database, raw : String) : Bool
      !db.find_entry(db.row_path(raw)).nil?
    rescue Doma::ValidationError
      false # relative input with no cwd: only the short_id reading is left
    end

    # Single-quote `raw` for a copy-pasteable hint when it has shell
    # metacharacters (spaces, quotes, ...); plain paths stay readable.
    private def shell_arg(raw : String) : String
      raw.matches?(/\A[A-Za-z0-9_.\/~+:@%,=-]+\z/) ? raw : "'#{raw.gsub("'", %q('\''))}'"
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
          return Doma::Trash.restore_hint(entry)
        end
      end

      if !raw.includes?('/') && !raw.includes?('.') && db.tag_names.includes?(raw)
        return "looks like a tag name. To untag a path: " \
               "doma rm <path> -t #{raw} (or `doma rename #{raw} <new>` to relabel)"
      end

      "to register it, run: doma add #{shell_arg(raw)}"
    end
  end
end
