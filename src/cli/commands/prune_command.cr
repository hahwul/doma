require "option_parser"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"

module Doma::CLI
  # Bulk-cleanup operations. Conceptually distinct from `rm <path>`:
  # `rm` is a *targeted* delete on a path the user named, while `prune`
  # sweeps the database for entries that match a class-level condition
  # (path missing on disk, tag past its TTL). Splitting them keeps the
  # safer single-target form free of bulk-only flags and makes the
  # destructive class-level forms self-announcing.
  class PruneCommand
    def run(args : Array(String))
      mode : Symbol? = nil

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma prune (--gone | --expired)"
        p.on("--gone", "Remove every entry whose path no longer exists on disk") do
          raise Doma::ValidationError.new("--gone and --expired cannot be combined") if mode
          mode = :gone
        end
        p.on("--expired", "Remove every tag whose TTL has elapsed") do
          raise Doma::ValidationError.new("--gone and --expired cannot be combined") if mode
          mode = :expired
        end
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
      parser.parse(args)

      raise Doma::ValidationError.new("prune requires --gone or --expired") unless mode

      case mode
      when :gone    then run_gone
      when :expired then run_expired
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
