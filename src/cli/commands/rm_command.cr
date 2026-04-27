require "option_parser"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/validator"

module Doma::CLI
  class RmCommand
    def run(args : Array(String))
      tags = [] of String
      gone = false
      expired = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma rm [<path> ...] [-t TAG ...] [--gone] [--expired]"
        p.on("-t TAG", "--tag=TAG", "Remove this tag (repeatable, comma-separated allowed)") do |t|
          t.split(',').each { |x| tags << x.strip unless x.strip.empty? }
        end
        p.on("--gone", "Remove every entry whose path no longer exists on disk") { gone = true }
        p.on("--expired", "Remove every tag whose TTL has elapsed") { expired = true }
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

      if gone && expired
        raise Doma::ValidationError.new("--gone and --expired cannot be combined")
      end

      if gone
        # `--gone` is mutually exclusive with explicit paths/tags: it's a
        # bulk maintenance operation, not a per-entry action. Refusing
        # the combination prevents surprises like "I asked to remove a
        # specific path, why did 12 others also disappear?"
        unless positional.empty? && tags.empty?
          raise Doma::ValidationError.new("--gone cannot be combined with paths or -t")
        end
        return run_gone
      end

      if expired
        unless positional.empty? && tags.empty?
          raise Doma::ValidationError.new("--expired cannot be combined with paths or -t")
        end
        return run_expired
      end

      raise Doma::ValidationError.new("path is required (or use --gone / --expired)") if positional.empty?

      # Validate up front so a misspelled or invalid tag name fails fast
      # with a clear error, instead of silently no-op'ing inside
      # `remove_tags` (where a non-existent tag name simply matches no
      # rows). Mirrors `add_command`'s validation step.
      cleaned_tags = tags.empty? ? tags : Doma::Validator.tags!(tags)

      db = Doma::Database.open
      begin
        positional.each do |path|
          if cleaned_tags.empty?
            if db.remove_path(path)
              Doma::Logger.success "removed #{Doma::Validator.canonicalize(path)}"
            else
              Doma::Logger.warn "not registered: #{path}"
            end
          else
            case db.remove_tags(path, cleaned_tags)
            in Doma::Database::RemoveTagsResult::Removed
              Doma::Logger.success "untagged #{Doma::Validator.canonicalize(path)} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NoMatch
              Doma::Logger.warn "no matching tag(s) on #{Doma::Validator.canonicalize(path)} (#{cleaned_tags.join(", ")})"
            in Doma::Database::RemoveTagsResult::NotRegistered
              Doma::Logger.warn "not registered: #{path}"
            end
          end
        end
      ensure
        db.close
      end
    end

    private def run_gone
      db = Doma::Database.open
      begin
        # List first so the user sees what was removed; reporting the
        # count alone leaves them guessing whether anything important
        # got swept up.
        dead = db.dead_paths
        if dead.empty?
          Doma::Logger.info "no missing paths to prune"
          return
        end

        dead.each { |e| Doma::Logger.info "  #{e.path}" }
        removed = db.prune_dead!
        Doma::Logger.success "pruned #{removed} missing path(s)"
      ensure
        db.close
      end
    end

    private def run_expired
      db = Doma::Database.open
      begin
        removed = db.prune_expired!
        if removed == 0
          Doma::Logger.info "no expired tags to prune"
        else
          Doma::Logger.success "pruned #{removed} expired tag association(s)"
        end
      ensure
        db.close
      end
    end
  end
end
