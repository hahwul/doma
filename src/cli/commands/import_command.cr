require "option_parser"
require "../../db/database"
require "../../services/git_status"
require "../../services/importer"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/runtime"
require "../../utils/validator"

module Doma::CLI
  class ImportCommand
    def run(args : Array(String))
      explicit_mode : Doma::Importer::Mode? = nil
      dry_run = false
      clone = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma import <file> [--merge | --replace] [--clone] [--dry-run] [--yes]"
        # Track each flag explicitly so passing both produces a hard
        # error instead of silently letting the second one win.
        p.on("--merge", "Add to existing data (default)") do
          if explicit_mode == Doma::Importer::Mode::Replace
            raise Doma::ValidationError.new("--merge and --replace are mutually exclusive")
          end
          explicit_mode = Doma::Importer::Mode::Merge
        end
        p.on("--replace", "Wipe existing data before importing") do
          if explicit_mode == Doma::Importer::Mode::Merge
            raise Doma::ValidationError.new("--merge and --replace are mutually exclusive")
          end
          explicit_mode = Doma::Importer::Mode::Replace
        end
        # `-y/--yes` is normally consumed by Runner's global-flag pass
        # before this parser ever sees it; the registration keeps the
        # flag documented in --help and routes to the same switch.
        p.on("-y", "--yes", "Skip the --replace confirmation prompt") { Doma::Runtime.assume_yes = true }
        p.on("--clone", "git clone entries that aren't on disk (needs remotes from `export --portable`)") { clone = true }
        p.on("-n", "--dry-run", "Report what would be imported without writing anything") { dry_run = true }
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

      raise Doma::ValidationError.new("input file is required") if positional.empty?
      file = Doma::Validator.canonicalize(positional.first)

      # `explicit_mode` keeps its `Mode?` type because it's assigned
      # inside the parser's blocks; the conditional unwrap below is what
      # convinces the compiler we're handing `from_file` a plain Mode.
      mode = explicit_mode.nil? ? Doma::Importer::Mode::Merge : explicit_mode.as(Doma::Importer::Mode)

      # A dry-run writes nothing, so the destructive `--replace` prompt
      # would be a lie — skip it and let the preview run freely.
      if mode == Doma::Importer::Mode::Replace && !dry_run && !Doma::Runtime.assume_yes?
        unless confirm_replace
          Doma::Logger.warn "aborted"
          exit 1
        end
      end

      # Before anything is written, not after the database is already merged.
      if clone && !Doma::GitStatus.available?
        raise Doma::Error.new("git executable not found on PATH", hint: "`--clone` shells out to git")
      end

      clonable = Doma::Database.open do |db|
        result = Doma::Importer.from_file(db, file, mode: mode, dry_run: dry_run)
        if dry_run
          verb = mode == Doma::Importer::Mode::Replace ? "replace" : "merge"
          Doma::Logger.info(
            "[dry-run] would #{verb}: #{result.imported} imported " \
            "(#{result.added} new, #{result.updated} existing), " \
            "#{result.skipped} skipped — nothing written"
          )
        elsif result.replaced
          # After a wipe every applied entry is new, so the breakdown
          # would just restate the total — keep the terse form.
          Doma::Logger.success "import replaced: #{result.imported} imported, #{result.skipped} skipped"
        else
          # Merge: spell out new vs already-present so a no-op re-import
          # (every entry already there) doesn't read as "N imported".
          Doma::Logger.success(
            "import merged: #{result.imported} imported " \
            "(#{result.added} new, #{result.updated} existing), #{result.skipped} skipped"
          )
        end
        result.clonable
      end

      return if clonable.empty?
      if !clone
        Doma::Logger.info "#{clonable.size} not on disk but have a remote — `--clone` fetches them"
      elsif dry_run
        clonable.each { |(path, remote)| Doma::Logger.info "[dry-run] would clone #{remote} → #{path}" }
      else
        clone_missing(clonable)
      end
    end

    # Parent paths first, so a repo nested inside another clones into it
    # instead of blocking it with a non-empty directory.
    # ponytail: one clone at a time; `Doma::Parallel` if onboarding a big
    # set is slow (keep nested paths ordered).
    private def clone_missing(clonable : Array({String, String}))
      failed = [] of String
      clonable.sort_by(&.[0]).each do |(path, remote)|
        # A parent cloned a moment ago may have brought this one with it.
        next unless Doma::Importer.absent?(path)
        # Cloning under a parent that just failed would create the parent
        # directory and block its retry.
        if failed.any? { |f| path.starts_with?("#{f}/") }
          failed << path
          Doma::Logger.warn "skipped #{path} (its parent failed to clone)"
          next
        end
        Doma::Logger.info "cloning #{remote} → #{path}"
        # The URL comes from a file: `--` keeps it from being read as an
        # option, and `ext::` (run-a-command transport) stays off even if
        # the user's git config allows it. git's progress goes to stderr;
        # stdout stays ours.
        ok = Process.run("git", ["-c", "protocol.ext.allow=never", "clone", "--", remote, path],
          output: STDERR, error: STDERR).success?
        unless ok
          failed << path
          Doma::Logger.warn "clone failed: #{path}"
        end
      end
      # The entries are registered either way; `list --check` shows the gaps.
      unless failed.empty?
        raise Doma::Error.new("#{failed.size} clone#{failed.size == 1 ? "" : "s"} failed")
      end
    end

    private def confirm_replace : Bool
      # In a non-interactive context (cron, pipe, CI) we can't actually ask
      # the user, so we refuse rather than silently destroy data. The
      # caller is expected to opt in explicitly with --yes.
      unless STDIN.tty?
        Doma::Logger.error "--replace requires --yes when stdin is not a TTY"
        return false
      end
      STDERR.print "This will wipe the current database. Continue? [y/N] "
      STDERR.flush
      raw = STDIN.gets
      return false if raw.nil?
      raw.strip.downcase.in?({"y", "yes"})
    end
  end
end
