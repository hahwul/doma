require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../services/picker"
require "../../utils/config"
require "../../utils/duration"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/suggester"

module Doma::CLI
  # Lists registered directories. Three filter dimensions, all optional
  # and composable:
  #
  #   doma list                 → everything
  #   doma list -t crystal      → exact tag match (was the only filter
  #                                originally)
  #   doma list crystl          → substring match across path/basename/
  #                                tag (replaces the old `search` command)
  #   doma list -t crystal foo  → both: tag-tagged AND containing "foo"
  class ListCommand
    def run(args : Array(String))
      tags = [] of String
      json_mode = false
      paths_only = false
      null_sep = false
      pick_mode = false
      pick_query : String? = nil
      pick_override : Doma::Settings::SelectorMode? = nil
      check_existence = false
      include_expired = false
      sort = Doma::Database::SortBy::Path
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma list [<query>] [-t TAG ...] [--by path|recent] [--check] [--include-expired] [--json] [--paths] [-0] [--pick]\n" \
                   "  (aliases for 'recent': 'used', 'recency')"
        # Repeatable / comma-separated, mirroring `add` and `rm`. Multiple
        # tags AND together — i.e. only directories carrying every listed
        # tag survive the filter. Pre-fix this clobbered to last-wins.
        p.on("-t TAG", "--tag=TAG", "Filter by tag (repeatable; AND semantics)") do |t|
          t.split(',').each { |x| tags << x.strip unless x.strip.empty? }
        end
        p.on("--by SORT", "Sort by 'path' (default) or 'recent' ('used'/'recency')") do |val|
          sort = case val
                 when "path" then Doma::Database::SortBy::Path
                 when "recent",
                      "used",
                      "recency" then Doma::Database::SortBy::Recent
                 else
                   raise Doma::ValidationError.new(
                     "--by must be 'path' or 'recent' (aliases: 'used', 'recency'), got '#{val}'"
                   )
                 end
        end
        p.on("--check", "Mark entries whose path is gone from disk") { check_existence = true }
        p.on("--include-expired", "Show tags whose TTL has elapsed") { include_expired = true }
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("--paths", "Print paths only") { paths_only = true }
        # `-0` implies `--paths` so a pipeline call stays short:
        # `doma list -t crystal -0 | xargs -0 grep TODO`
        p.on("-0", "--print0", "Print paths only, NUL-separated (xargs -0)") do
          paths_only = true
          null_sep = true
        end
        # Single-element resolution: print one path so the shell can `cd`
        # to it. Replaces the old top-level `cd` command — the shell
        # wrapper (doma setup install) calls this under the hood.
        # Multiple matches + TTY → interactive picker; non-TTY → first
        # (most-recent) with an ambiguity warning on stderr.
        p.on("--pick", "Resolve to a single path (interactive if TTY)") { pick_mode = true }
        p.on("--query Q", "Pre-fill the picker filter (used with --pick)") { |q| pick_query = q }
        p.on("--first", "With --pick: always pick the first match (no prompt)") do
          pick_override = Doma::Settings::SelectorMode::First
        end
        p.on("--builtin", "With --pick: force interactive picker even when stdin is not a TTY") do
          pick_override = Doma::Settings::SelectorMode::Builtin
        end
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

      query = positional.empty? ? nil : positional.join(" ")
      tags.uniq!

      if pick_mode && (json_mode || paths_only)
        raise Doma::ValidationError.new("--pick is incompatible with --json / --paths / -0")
      end
      if pick_query && !pick_mode
        raise Doma::ValidationError.new("--query requires --pick")
      end
      if pick_override && !pick_mode
        raise Doma::ValidationError.new("--first/--builtin require --pick")
      end

      db = Doma::Database.open
      begin
        entries = collect(db, tags, query, sort, include_expired)

        if pick_mode
          run_pick(db, entries, pick_query, pick_override, tags, query)
          return
        end

        if json_mode
          payload = entries.map do |e|
            row = {
              "id"       => JSON::Any.new(e.id),
              "short_id" => JSON::Any.new(e.short_id),
              "path"     => JSON::Any.new(e.path),
              "basename" => JSON::Any.new(e.basename),
              "tags"     => JSON::Any.new(e.tags.map { |t| JSON::Any.new(t) }),
            }
            # `expirations` matches the export/import schema (tag_name =>
            # unix epoch). Only attached when at least one tag has a TTL,
            # so the common all-permanent case stays diff-friendly.
            ttl_map = db.tag_expirations(e.id, include_past: include_expired)
            unless ttl_map.empty?
              row["expirations"] = JSON::Any.new(ttl_map.transform_values { |v| JSON::Any.new(v) })
            end
            row["exists"] = JSON::Any.new(Dir.exists?(e.path)) if check_existence
            row
          end
          puts payload.to_json
          return
        end

        if entries.empty?
          STDERR.puts(empty_message(tags, query))
          # Only suggest for literal (non-glob) tag names that aren't in
          # the catalog at all. An empty AND intersection between two
          # known tags is a legitimate result, not a typo.
          if hint = typo_hint(db, tags)
            STDERR.puts "  #{hint}"
          end
          # First-run cue: an unfiltered, empty DB is almost always a
          # newcomer who just installed and ran `list` to see what doma
          # does. Point them at the obvious next step.
          if tags.empty? && query.nil? && db.directories.empty?
            STDERR.puts "  hint: try `doma add .` to register the current directory"
          end
          return
        end

        if paths_only
          # Each value is *terminated* (not just separated) by the chosen
          # delimiter, matching `find -print0` semantics so xargs -0 sees
          # a clean N-record stream.
          sep = null_sep ? '\0' : '\n'
          entries.each { |e| STDOUT.print(e.path); STDOUT.print(sep) }
          return
        end

        color = Doma::Logger.color_enabled?
        entries.each do |e|
          # short_id is shown dim so the eye lands on path/tags first
          # but it's still copy-pasteable for `doma cd <id>`.
          short_str = color ? e.short_id.colorize(:dark_gray).to_s : e.short_id
          path_str = color ? e.path.colorize(:cyan).to_s : e.path
          ttl_map = db.tag_expirations(e.id, include_past: include_expired)
          tags_str = e.tags.empty? ? "" : e.tags.map { |t| render_tag(t, ttl_map[t]?, color) }.join(' ')
          marker = ""
          if check_existence && !Dir.exists?(e.path)
            marker = color ? " #{"[gone]".colorize(:red)}" : " [gone]"
          end
          puts "#{short_str}  #{path_str}\t#{tags_str}#{marker}"
        end

        # Footer: when expired rows were filtered out, surface the count
        # and the flag that would reveal them. Symmetrical with the
        # `[gone]` story for missing paths — silent suppression is a UX
        # trap if the user is wondering why they don't see something.
        unless include_expired
          hidden = db.expired_tag_count
          if hidden > 0
            noun = hidden == 1 ? "tag" : "tags"
            STDERR.puts "  #{hidden} #{noun} hidden by TTL — pass --include-expired to show"
          end
        end
      ensure
        db.close
      end
    end

    # Narrow the filtered entries down to one path and print it to stdout.
    # Single-element output mode designed to compose with the shell
    # wrapper installed by `doma setup install` — that wrapper captures
    # this output and runs `cd` itself, since a child process can't
    # change its parent's working directory.
    #
    # Resolution rules:
    #   - 0 entries          → NotFoundError (with a hint that points
    #                          at `doma add` when the input looks like a
    #                          filesystem path)
    #   - 1 entry            → print and stamp recency
    #   - N entries + TTY    → interactive picker; cancellation is exit 130
    #   - N entries + no TTY → most-recent wins, with a stderr warning so
    #                          callers piping `--pick` don't silently get
    #                          a heuristic pick they didn't expect
    private def run_pick(db : Doma::Database, entries : Array(Doma::Entry), pick_query : String?, pick_override : Doma::Settings::SelectorMode?, tags : Array(String), query : String?)
      if entries.empty?
        raise Doma::NotFoundError.new(
          empty_message(tags, query),
          hint: pick_miss_hint(db, tags, query)
        )
      end

      items = entries.map do |e|
        tags_hint = e.tags.empty? ? nil : e.tags.map { |t| "##{t}" }.join(' ')
        Doma::Picker::Item.new(value: e.path, label: e.path, hint: tags_hint)
      end
      items = Doma::Picker.filter(items, pick_query) if pick_query

      if items.empty?
        raise Doma::NotFoundError.new("no directories match '#{pick_query}'") if pick_query
        raise Doma::NotFoundError.new(empty_message(tags, query))
      end

      if items.size == 1
        chosen = items.first.value
        bump_used_safe(db, chosen)
        puts chosen
        return
      end

      effective = pick_override || Doma::Settings.current.selector
      if effective == Doma::Settings::SelectorMode::Auto
        effective = STDIN.tty? ? Doma::Settings::SelectorMode::Builtin : Doma::Settings::SelectorMode::First
      end

      case effective
      in Doma::Settings::SelectorMode::Builtin
        prompt = pick_prompt(tags, query)
        result = Doma::Picker.pick(items, prompt)
        raise Doma::Error.new("selection cancelled", 130) if result.cancelled
        if value = result.value
          bump_used_safe(db, value)
          puts value
        end
      in Doma::Settings::SelectorMode::First
        # Deterministic auto-pick. Warn so scripted callers don't silently
        # get a heuristic choice they didn't expect.
        unless Doma::Logger.quiet?
          first_tag = tags.first?
          context = first_tag ? "tag '#{first_tag}'" : "current filter"
          Doma::Logger.warn(
            "#{context} matches #{items.size} directories; picked first. " \
            "Pass --by recent or refine the filter to disambiguate."
          )
        end
        chosen = items.first.value
        bump_used_safe(db, chosen)
        puts chosen
      in Doma::Settings::SelectorMode::Auto
        # Already resolved above; this branch satisfies exhaustiveness.
        puts items.first.value
      end
    end

    private def bump_used_safe(db : Doma::Database, path : String)
      db.bump_used!(path)
    rescue
      # Frecency is best-effort — never block the actual output.
    end

    # Mirror cd's old miss-hint: when the user passes a path-like string
    # (`/foo`, `~/x`, `./bar`), they probably meant to register it. Steer
    # them to `doma add` instead of suggesting an unrelated tag.
    private def pick_miss_hint(db : Doma::Database, tags : Array(String), query : String?) : String?
      candidate = tags.first? || query
      return unless candidate
      if path_like?(candidate)
        return "to register this path, run: doma add #{candidate}"
      end
      Doma::Suggester.hint_for(candidate, db.tag_names)
    end

    private def path_like?(input : String) : Bool
      input.starts_with?('/') ||
        input.starts_with?('~') ||
        input.starts_with?("./") ||
        input.starts_with?("../") ||
        input == "."
    end

    private def pick_prompt(tags : Array(String), query : String?) : String
      parts = [] of String
      tags.each { |t| parts << "-t #{t}" }
      parts << query if query
      parts.empty? ? "doma pick" : "doma pick #{parts.join(' ')}"
    end

    # Compose the two filters. Doing the intersection client-side keeps
    # the SQL straightforward — both `directories(tag)` and `search(query)`
    # already exist and are tested in isolation. Multi-tag AND is layered
    # on top by intersecting per-tag id sets.
    private def collect(db : Doma::Database, tags : Array(String), query : String?, sort : Doma::Database::SortBy, include_expired : Bool) : Array(Doma::Entry)
      base = if tags.empty?
               query ? db.search(query, include_expired: include_expired) : db.directories(sort: sort, include_expired: include_expired)
             else
               # Anchor on the first tag (gets the right `sort`/`include_expired`
               # treatment), then narrow by intersecting against each
               # additional tag's id set. Empty additional set short-circuits
               # to no matches without further DB work.
               first, *rest = tags
               anchor = db.directories(first, sort: sort, include_expired: include_expired)
               rest.each do |t|
                 break if anchor.empty?
                 ids = db.directories(t, sort: sort, include_expired: include_expired).map(&.id).to_set
                 anchor = anchor.select { |e| ids.includes?(e.id) }
               end
               anchor
             end

      return base if query.nil? || tags.empty?

      tagged_ids = base.map(&.id).to_set
      db.search(query, include_expired: include_expired).select { |e| tagged_ids.includes?(e.id) }
    end

    private def empty_message(tags : Array(String), query : String?) : String
      tag_phrase = tag_phrase(tags)
      if tag_phrase && query
        "no matches for '#{query}' tagged #{tag_phrase}"
      elsif tag_phrase
        "no directories tagged #{tag_phrase}"
      elsif query
        "no matches for '#{query}'"
      else
        "no directories registered"
      end
    end

    private def tag_phrase(tags : Array(String)) : String?
      return if tags.empty?
      return "'#{tags.first}'" if tags.size == 1
      tags.map { |t| "'#{t}'" }.join(" AND ")
    end

    # Decorate `#tag` with a `~3d` / `~expired` suffix when the tag has
    # a TTL. The suffix uses the same compact form (`Nu`) the parser
    # accepts, so a glance at the listing tells you what to renew. An
    # already-lapsed TTL renders red instead of dim so it pops next to
    # active rows when --include-expired surfaces them.
    private def render_tag(tag : String, expires_at : Int64?, color : Bool) : String
      base = color ? "##{tag}".colorize(:yellow).to_s : "##{tag}"
      return base unless expires_at
      remaining = Doma::Duration.humanize_remaining(expires_at)
      suffix = "~#{remaining}"
      return "#{base}#{suffix}" unless color
      tinted = remaining == "expired" ? suffix.colorize(:red) : suffix.colorize(:dark_gray)
      "#{base}#{tinted}"
    end

    # Pick the first tag the user typed that doesn't actually exist (and
    # isn't a glob) and propose the closest catalog name. Stops at one
    # hint to keep the noise floor low when several tags are bogus.
    private def typo_hint(db : Doma::Database, tags : Array(String)) : String?
      return if tags.empty?
      catalog = db.tag_names
      known = catalog.to_set
      tags.each do |t|
        next if t.includes?('*') || t.includes?('?')
        next if known.includes?(t)
        if hint = Doma::Suggester.hint_for(t, catalog)
          return hint
        end
      end
      nil
    end
  end
end
