require "option_parser"
require "../../db/database"
require "../../services/trash"
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
      hard = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma prune (--gone | --expired) [--hard]"
        p.on("--gone", "Remove every entry whose path no longer exists on disk") do
          raise Doma::ValidationError.new("--gone and --expired cannot be combined") if mode
          mode = :gone
        end
        p.on("--expired", "Remove every tag whose TTL has elapsed") do
          raise Doma::ValidationError.new("--gone and --expired cannot be combined") if mode
          mode = :expired
        end
        # Mirrors `rm --hard`. With it, --gone skips the trash snapshot
        # and deletes entries permanently; without it, dead entries are
        # recoverable via `doma trash restore <id>` for 7 days.
        # `--expired` only removes (path, tag) bindings (the path
        # itself stays), so it has nothing meaningful to snapshot —
        # `--hard` is silently a no-op there.
        p.on("--hard", "Skip the trash; delete permanently") { hard = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
      parser.parse(args)

      raise Doma::ValidationError.new("prune requires --gone or --expired") unless mode

      case mode
      when :gone    then run_gone(hard)
      when :expired then run_expired
      end
    end

    private def run_gone(hard : Bool)
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

        if hard
          removed = db.prune_dead!
          Doma::Logger.success "pruned #{removed} missing path(s) (permanent)"
          return
        end

        # Default path: route the dead entries through the same trash
        # store `rm` writes to. A briefly-unmounted external disk or
        # NAS made `prune --gone` data-destructive in the previous
        # implementation — one mistaken sweep and every tag was gone
        # for good. With trash on by default the same sweep is fully
        # reversible for 7 days; --hard preserves the old behavior
        # for users who actually want it.
        #
        # Snapshot and delete the *same* set: pair each snapshot with the
        # row id it came from and delete exactly those ids. Calling
        # `prune_dead!` here instead would re-stat every row, and a path
        # that reappeared between `dead_paths` above and that second pass
        # would be snapshotted into the trash yet never deleted — a
        # phantom, un-restorable trash entry for a row that's still live.
        pending = dead.compact_map do |e|
          snap = Doma::Trash.snapshot(db, e.path)
          snap ? {e.id, snap} : nil
        end
        removed = db.remove_ids!(pending.map { |(id, _)| id })
        pending.each { |(_, snap)| Doma::Trash.add!(snap) }
        sample_ids = pending.first(3).map { |(_, snap)| snap.short_id[0..6] }.join(", ")
        more = pending.size > 3 ? ", ..." : ""
        Doma::Logger.success(
          "trashed #{removed} missing path(s) " \
          "(restore with `doma trash restore #{sample_ids}#{more}`)"
        )
      ensure
        db.close
      end
    end

    private def run_expired
      db = Doma::Database.open
      begin
        removed = db.prune_expired!
        if removed.empty?
          Doma::Logger.info "no expired tags to prune"
        else
          # Mirror `prune --gone` — list what got removed before the
          # summary so the user can audit. One line per (path, tag)
          # pair; tags shown with the `#` sigil for parity with `list`.
          removed.each { |r| Doma::Logger.info "  #{r.path}\t##{r.tag}" }
          Doma::Logger.success "pruned #{removed.size} expired tag association(s)"
        end
      ensure
        db.close
      end
    end
  end
end
