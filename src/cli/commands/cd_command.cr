require "option_parser"
require "../../db/database"
require "../../services/picker"
require "../../services/selector"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/short_id_resolver"
require "../../utils/suggester"

module Doma::CLI
  # Resolves a directory and prints it to stdout — designed to compose
  # with the `doma init` shell wrapper so the parent shell actually `cd`s.
  # Two modes:
  #
  #   doma cd <tag>   — pick from directories carrying that tag
  #   doma cd         — browse every registered directory; the picker
  #                     shows the path on the left and tags greyed out on
  #                     the right so you can navigate by either.
  class CdCommand
    def run(args : Array(String))
      mode_override : Doma::Settings::SelectorMode? = nil
      index : Int32? = nil
      query : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma cd [<tag>] [--first | --builtin | --index N]"
        p.on("--index N", "Pick the N-th match (1-based)") do |n|
          parsed = n.to_i?
          raise Doma::ValidationError.new("--index must be an integer, got '#{n}'") unless parsed
          index = parsed
        end
        p.on("--first", "Pick the first match without prompting") do
          mode_override = Doma::Settings::SelectorMode::First
        end
        p.on("--builtin", "Force the interactive picker even when stdin is not a TTY") do
          mode_override = Doma::Settings::SelectorMode::Builtin
        end
        p.on("--query Q", "Pre-fill the picker filter (no-tag mode)") { |q| query = q }
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

      if positional.empty?
        run_browse(mode_override, query)
      else
        run_for_tag(positional.first, mode_override, index)
      end
      maybe_emit_wrapper_hint
    end

    # If `doma cd`'s stdout is a TTY, the shell wrapper isn't capturing
    # our output — meaning `cd` won't actually happen. Tell the user
    # once. We persist a marker file so subsequent invocations stay
    # silent (the user might genuinely want raw path output).
    private def maybe_emit_wrapper_hint
      return unless STDOUT.tty?
      marker = Doma::Config.cd_hint_marker
      return if File.exists?(marker)

      Doma::Logger.warn "doma cd printed the path but didn't change directory."
      STDERR.puts "  The shell wrapper isn't loaded. Set it up once with:"
      STDERR.puts "      doma setup install"
      STDERR.puts "  (this hint won't appear again)"

      Doma::Config.ensure_home!
      File.write(marker, "")
    rescue
      # Never let hint plumbing break the actual command.
    end

    private def run_for_tag(tag : String, mode : Doma::Settings::SelectorMode?, index : Int32?)
      db = Doma::Database.open
      begin
        # Resolution order:
        #   1. Tag name match — the typical case
        #   2. short_id prefix — `doma cd 0dc0db9` (or any unique
        #      prefix). Only consulted when there's no tag match, so
        #      a literal tag named `abc` still wins over a short_id
        #      that happens to start with `abc`.
        paths = db.paths_for_tag(tag)
        if paths.empty?
          if direct = Doma::ShortIdResolver.resolve(db, tag)
            bump_used_safe(db, direct)
            puts direct
            return
          end

          raise Doma::NotFoundError.new(
            "no directories tagged '#{tag}' (and no matching short_id)",
            hint: Doma::Suggester.hint_for(tag, db.tag_names)
          )
        end

        chosen = if idx = index
                   unless idx >= 1 && idx <= paths.size
                     raise Doma::ValidationError.new("index out of range (1..#{paths.size})")
                   end
                   paths[idx - 1]
                 else
                   result = Doma::Selector.pick(paths, prompt: "doma cd #{tag}", mode: mode)
                   raise Doma::Error.new("selection cancelled", 130) if result.cancelled
                   result.value
                 end

        # Reuse the already-open connection rather than open() / close()
        # / open() / close() — saves one DB.open per cd.
        bump_used_safe(db, chosen)
        puts chosen
      ensure
        db.close
      end
    end

    # Full browse: every registered directory, with tags rendered as a
    # greyed-out hint column so the user can scan by tag context without
    # losing the path. Falls back deterministically to `:first` when
    # stdin is not a TTY (scripts/pipes) so callers never hang.
    private def run_browse(mode : Doma::Settings::SelectorMode?, query : String?)
      db = Doma::Database.open
      begin
        entries = db.directories
        raise Doma::NotFoundError.new("no directories registered") if entries.empty?

        # Apply --query *before* mode dispatch so it works in every
        # context — including non-TTY (First) where there's no picker
        # to do the filtering interactively. Earlier, the First branch
        # ignored --query and silently returned the first overall entry.
        items = entries.map do |e|
          tags_hint = e.tags.empty? ? nil : e.tags.map { |t| "##{t}" }.join(' ')
          Doma::Picker::Item.new(value: e.path, label: e.path, hint: tags_hint)
        end
        items = Doma::Picker.filter(items, query) if query

        if items.empty?
          raise Doma::NotFoundError.new("no directories match '#{query}'") if query
          raise Doma::NotFoundError.new("no directories registered")
        end

        effective = mode || Doma::Settings.current.selector
        effective = STDIN.tty? ? Doma::Settings::SelectorMode::Builtin : Doma::Settings::SelectorMode::First if effective == Doma::Settings::SelectorMode::Auto

        case effective
        in Doma::Settings::SelectorMode::First
          chosen = items.first.value
          bump_used_safe(db, chosen)
          puts chosen
        in Doma::Settings::SelectorMode::Builtin
          result = Doma::Picker.pick(items, "doma cd")
          raise Doma::Error.new("selection cancelled", 130) if result.cancelled
          if value = result.value
            bump_used_safe(db, value)
            puts value
          end
        in Doma::Settings::SelectorMode::Auto
          # Already resolved above; this branch satisfies exhaustiveness.
          puts items.first.value
        end
      ensure
        db.close
      end
    end

    # Best-effort recency stamp on the already-open connection. WAL mode
    # means this UPDATE doesn't block other readers, and the rescue
    # guarantees frecency tracking can never fail the actual `cd`.
    private def bump_used_safe(db : Doma::Database, path : String)
      db.bump_used!(path)
    rescue
      # Frecency is best-effort.
    end
  end
end
