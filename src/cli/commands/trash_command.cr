require "option_parser"
require "../../db/database"
require "../../services/trash"
require "../../tui/text"
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
      puts "  list [--json]          What's recoverable (newest first); --json for machine-readable"
      puts "  restore [<short_id>]   Bring an entry back — newest if no id given (--merge for collisions)"
      puts "  empty [--json]         Purge everything in the trash"
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
      json_mode = false
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma trash list [--json]"
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args { |before, after| reject_stray!(before + after) }
      end

      entries = Doma::Trash.entries
      if entries.empty?
        if json_mode
          puts "[]"
        else
          Doma::Logger.info "trash is empty"
        end
        return
      end

      if json_mode
        puts entries.to_json
        return
      end

      now = Time.utc.to_unix
      puts "ID       AGE   PATH                                                TAGS"
      entries.each do |e|
        id = e.display_id.ljust(7)
        # Compact age ("3d", "5h", "now") in the same `Nu` form as TTLs,
        # so `trash list` and `list --include-expired` read alike.
        delta = now - e.deleted_at
        age = (delta < 60 ? "now" : Doma::Duration.compact(delta)).rjust(5)
        # Truncate from the left with an ellipsis so the *end* of the
        # path (the part that disambiguates similar entries) stays
        # visible. Final ljust pads short paths to the same column width.
        # Display width, not `size`: a CJK/Hangul char takes two columns.
        path = Doma::TUI::Text.display_width(e.path) > 50 ? "…#{Doma::TUI::Text.tail_fit(e.path, 49)}" : e.path
        pad = " " * (51 - Doma::TUI::Text.display_width(path))
        tags = e.tags.empty? ? "-" : e.tags.join(",")
        puts "#{id}  #{age}  #{path}#{pad} #{tags}"
      end
    end

    private def cmd_restore(args : Array(String))
      merge = false
      positional = [] of String
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma trash restore [<short_id>] [--merge]   (no id → restore the newest)"
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

      reject_stray!(positional[1..]) if positional.size > 1

      entry =
        if positional.empty?
          # Bare `doma trash restore` = undo the most recent deletion,
          # the overwhelmingly common "I just rm'd the wrong thing" case
          # (no need to `trash list`, copy a hex id, and retype it).
          # entries() is newest-first, so the head is the last thing rm'd.
          Doma::Trash.entries.first? || raise Doma::NotFoundError.new("trash is empty — nothing to restore")
        else
          prefix = positional.first.downcase
          unless prefix.matches?(/\A[0-9a-f]+\z/)
            raise Doma::ValidationError.new("short_id must be hex: '#{positional.first}'")
          end
          Doma::Trash.find_by_short_id(prefix) || raise Doma::NotFoundError.new("no trash entry matching '#{prefix}'")
        end

      Doma::Database.open do |db|
        merged = Doma::Trash.restore!(db, entry, merge: merge)
        suffix = merged ? " (merged into existing row)" : ""
        Doma::Logger.success "restored #{entry.path}#{suffix}"
      end
    end

    private def cmd_empty(args : Array(String))
      older : Int64? = nil
      json_mode = false
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma trash empty [--older DUR] [--json]"
        p.on("--older=DUR", "Only purge entries older than DUR (e.g. 7d, 24h)") do |v|
          older = Doma::Duration.parse_seconds!(v)
        end
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        # `trash empty 30d -y` must not silently become "purge everything".
        p.unknown_args do |before, after|
          stray = before + after
          unless stray.empty?
            raise Doma::ValidationError.new("unexpected argument '#{stray.first}' (did you mean --older #{stray.first}?)")
          end
        end
      end

      # Pre-count so we can both (a) skip the prompt entirely on an empty
      # trash and (b) phrase the prompt with a real number ("Purge 4
      # entries?" reads less abstract than "Purge everything?").
      cutoff = older.try { |age| Time.utc.to_unix - age }
      targets = Doma::Trash.entries(prune: false).select { |e| cutoff.nil? || e.deleted_at < cutoff }
      pending = targets.size

      if pending == 0
        if json_mode
          puts %({"purged":0})
        else
          Doma::Logger.info "nothing to purge"
        end
        return
      end

      # Confirmation gate. `rm <path>` writes to the trash by default
      # (soft delete), so `trash empty` is the moment those snapshots
      # actually become unrecoverable — a quiet purge here is a UX
      # footgun. Honors -y/--yes and DOMA_YES=1 for the scripted case;
      # non-interactive without either is a hard refusal (see `confirm?`),
      # matching `import --replace` and `install`.
      noun = pending == 1 ? "entry" : "entries"
      scope_phrase = older.nil? ? "" : " (older than threshold)"
      unless confirm?("Purge #{pending} trash #{noun}#{scope_phrase}? This cannot be undone.")
        if json_mode
          puts %({"aborted":true,"pending":#{pending}})
        else
          Doma::Logger.warn "aborted"
        end
        exit 1
      end

      # Purge exactly what the prompt counted: an `rm` in another shell
      # while the prompt waits must stay recoverable.
      removed = Doma::Trash.empty!(only: targets)
      if json_mode
        puts %({"purged":#{removed}})
      else
        if removed == 0
          Doma::Logger.info "nothing to purge"
        else
          Doma::Logger.success "purged #{removed} trash entr#{removed == 1 ? "y" : "ies"}#{scope_phrase}"
        end
      end
    end

    private def reject_stray!(stray : Array(String))
      return if stray.empty?
      raise Doma::ValidationError.new("unexpected argument '#{stray.first}'")
    end

    # Yes/no prompt with the standard escape hatches. `-y` / `--yes` /
    # `DOMA_YES=1` short-circuits to true. A non-TTY session without
    # either is a hard "no" rather than an auto-yes — we can't actually
    # ask, and this purge is unrecoverable, so silently assuming consent
    # would turn a stray non-interactive invocation (cron, a pipe, a
    # wrapper script) into permanent data loss. Same rule as `import
    # --replace` and `install`: an unattended run must opt in with -y.
    private def confirm?(question : String) : Bool
      return true if Doma::Runtime.assume_yes?
      unless STDIN.tty? && STDOUT.tty?
        Doma::Logger.error "trash empty requires --yes (or DOMA_YES=1) when stdin is not a TTY"
        return false
      end
      STDOUT.print "#{question} [y/N] "
      STDOUT.flush
      reply = STDIN.gets || ""
      reply.strip.downcase.in?({"y", "yes"})
    end
  end
end
