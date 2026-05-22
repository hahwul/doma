require "option_parser"
require "../../db/database"
require "../../services/trash"
require "../../utils/duration"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/runtime"
require "../../utils/suggester"

module Doma::CLI
  # `doma trash <list|restore|empty>` — surface for the soft-delete
  # recovery store written by `rm`. See `Doma::Trash` for the on-disk
  # format and retention semantics.
  class TrashCommand
    ACTIONS = %w[list ls restore empty]

    def run(args : Array(String))
      action = args.shift?
      case action
      when nil, "-h", "--help", "help"
        print_help
      when "list", "ls"
        cmd_list(args)
      when "restore"
        cmd_restore(args)
      when "empty"
        cmd_empty(args)
      else
        Doma::Logger.error "unknown trash action '#{action}'"
        if suggestion = Doma::Suggester.suggest(action, ACTIONS)
          STDERR.puts "  Did you mean '#{suggestion}'?"
        end
        STDERR.puts "Run 'doma trash --help' to see actions."
        exit 1
      end
    end

    private def print_help
      puts "Usage: doma trash <action> [args]"
      puts ""
      puts "Actions:"
      puts "  list                   What's recoverable (newest first)"
      puts "  restore <short_id>     Bring an entry back (use --merge for collisions)"
      puts "  empty                  Purge everything in the trash"
      puts "  empty --older DUR      Purge only entries deleted before DUR ago"
      puts ""
      puts "Notes:"
      puts "  - `rm <path>` writes to the trash by default; --hard bypasses it."
      puts "  - Anything older than 7d is auto-pruned on the next trash op."
    end

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    private def cmd_list(args : Array(String))
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma trash list"
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end

      entries = Doma::Trash.entries
      if entries.empty?
        Doma::Logger.info "trash is empty"
        return
      end

      now = Time.utc.to_unix
      puts "ID       AGE   PATH                                                TAGS"
      entries.each do |e|
        id = e.short_id[0..6].ljust(7)
        age = humanize_age(now - e.deleted_at).rjust(5)
        # Truncate from the left with an ellipsis so the *end* of the
        # path (the part that disambiguates similar entries) stays
        # visible. Final ljust pads short paths to the same column width.
        path = e.path.size > 50 ? "…#{e.path[-49..-1]}" : e.path
        tags = e.tags.empty? ? "-" : e.tags.join(",")
        puts "#{id}  #{age}  #{path.ljust(51)} #{tags}"
      end
    end

    private def cmd_restore(args : Array(String))
      merge = false
      positional = [] of String
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma trash restore <short_id> [--merge]"
        p.on("--merge", "Merge tags if the path is already registered") { merge = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args do |before, after|
          positional.concat(before)
          positional.concat(after)
        end
      end

      if positional.empty?
        raise Doma::ValidationError.new("short_id is required",
          "Usage: doma trash restore <short_id> [--merge]")
      end

      prefix = positional.first.downcase
      unless prefix.matches?(/\A[0-9a-f]+\z/)
        raise Doma::ValidationError.new("short_id must be hex: '#{positional.first}'")
      end

      entry = Doma::Trash.find_by_short_id(prefix)
      unless entry
        raise Doma::NotFoundError.new("no trash entry matching '#{prefix}'")
      end

      db = Doma::Database.open
      begin
        Doma::Trash.restore!(db, entry, merge: merge)
        suffix = merge ? " (merged into existing row)" : ""
        Doma::Logger.success "restored #{entry.path}#{suffix}"
      ensure
        db.close
      end
    end

    private def cmd_empty(args : Array(String))
      older : Int64? = nil
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma trash empty [--older DUR]"
        p.on("--older=DUR", "Only purge entries older than DUR (e.g. 7d, 24h)") do |v|
          older = Doma::Duration.parse_seconds!(v)
        end
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end

      # Pre-count so we can both (a) skip the prompt entirely on an empty
      # trash and (b) phrase the prompt with a real number ("Purge 4
      # entries?" reads less abstract than "Purge everything?").
      pending = if cutoff_age = older
                  cutoff = Time.utc.to_unix - cutoff_age
                  Doma::Trash.entries(prune: false).count { |e| e.deleted_at < cutoff }
                else
                  Doma::Trash.entries(prune: false).size
                end

      if pending == 0
        Doma::Logger.info "nothing to purge"
        return
      end

      # Confirmation gate. `rm <path>` writes to the trash by default
      # (soft delete), so `trash empty` is the moment those snapshots
      # actually become unrecoverable — a quiet purge here is a UX
      # footgun. Honors -y/--yes and DOMA_YES=1 for the scripted case.
      noun = pending == 1 ? "entry" : "entries"
      scope_phrase = older.nil? ? "" : " (older than threshold)"
      unless confirm?("Purge #{pending} trash #{noun}#{scope_phrase}? This cannot be undone.")
        Doma::Logger.info "aborted"
        return
      end

      removed = Doma::Trash.empty!(older_seconds: older)
      if removed == 0
        Doma::Logger.info "nothing to purge"
      else
        scope = older.nil? ? "" : " (older than threshold)"
        Doma::Logger.success "purged #{removed} trash entr#{removed == 1 ? "y" : "ies"}#{scope}"
      end
    end

    # Yes/no prompt with the standard escape hatches. `-y` / `--yes` /
    # `DOMA_YES=1` short-circuits to true; a non-TTY without those flags
    # also short-circuits to true so existing scripts that piped to
    # `trash empty` keep working — the new gate only fires for genuinely
    # interactive sessions where the user could be surprised.
    private def confirm?(question : String) : Bool
      return true if Doma::Runtime.assume_yes?
      return true unless STDIN.tty? && STDOUT.tty?
      STDOUT.print "#{question} [y/N] "
      STDOUT.flush
      reply = STDIN.gets || ""
      reply.strip.downcase.in?({"y", "yes"})
    end

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    # Compact age renderer: "3d", "5h", "12m", "now". Mirrors the style
    # of `Doma::Duration.humanize_remaining` so the columns in `trash
    # list` and `list --include-expired` look the same.
    private def humanize_age(seconds : Int64) : String
      return "now" if seconds < 60
      return "#{seconds // 60}m" if seconds < 3600
      return "#{seconds // 3600}h" if seconds < 86_400
      "#{seconds // 86_400}d"
    end
  end
end
