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
require "../../utils/tag_glob"
require "../../utils/tag_renderer"

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
    # Sentinel returned to the renderer when an entry has no TTL'd tags
    # at all, so the inner `t -> TagRenderer.render(t, ttl_map[t]?, color)`
    # loop never has to special-case "no entry in the bulk map." Frozen
    # at module load time and never mutated.
    private EMPTY_TTL = {} of String => Int64

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
      group_by_tag = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma list [<query>] [-t TAG ...] [--by path|recent|tag] [--check] [--include-expired] [--json] [--paths] [-0] [--pick]\n" \
                   "  (aliases for 'recent': 'used', 'recency')"
        # Repeatable / comma-separated, mirroring `add` and `rm`. Multiple
        # tags AND together — i.e. only directories carrying every listed
        # tag survive the filter. Pre-fix this clobbered to last-wins.
        p.on("-t TAG", "--tag=TAG", "Filter by tag (repeatable; AND semantics)") do |t|
          # Reject `-t ''`, `-t '   '`, and `-t ',,'` — anything that
          # would collapse to an empty filter and silently match every
          # path. Mirrors the add/rm/mark/run validation.
          parts = t.split(',').map(&.strip).reject(&.empty?)
          if parts.empty?
            raise Doma::ValidationError.new("tag is empty (-t got an empty value)")
          end
          parts.each { |x| tags << x }
        end
        p.on("--by SORT", "Sort by 'path' (default), 'recent' ('used'/'recency'), or 'tag' (group)") do |val|
          case val
          when "path"
            sort = Doma::Database::SortBy::Path
          when "recent", "used", "recency"
            sort = Doma::Database::SortBy::Recent
          when "tag"
            # `tag` is a *grouping* mode rather than a flat sort: one
            # entry can carry N tags and shows up under each. Internal
            # row order within a group still uses path-asc so the output
            # is stable across runs.
            group_by_tag = true
            sort = Doma::Database::SortBy::Path
          else
            raise Doma::ValidationError.new(
              "--by must be 'path', 'recent' (aliases: 'used', 'recency'), or 'tag', got '#{val}'"
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
      if group_by_tag && pick_mode
        # --pick resolves to a single path; grouping by tag is purely a
        # display dimension that doesn't fit a single-path result.
        raise Doma::ValidationError.new("--by tag is incompatible with --pick")
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

        # Hydrate every entry's TTL map once so the per-row loops below
        # (both JSON and text rendering) can do a hash lookup instead of
        # a fresh SQL round trip per entry. Empty hash for an entry with
        # all-permanent tags falls out naturally.
        ttl_by_id = db.tag_expirations_bulk(entries.map(&.id), include_past: include_expired)

        if json_mode
          emit_json(entries, ttl_by_id, group_by_tag, check_existence)
          return
        end

        if entries.empty?
          report_empty(db, tags, query)
          return
        end

        if paths_only
          emit_paths(entries, group_by_tag, null_sep)
          return
        end

        emit_text(db, entries, ttl_by_id, group_by_tag, check_existence, include_expired)
      ensure
        db.close
      end
    end

    # Emit entries as JSON — a flat array, or an object keyed by tag name
    # when grouping. Matches the export/import row schema via `json_row`.
    private def emit_json(entries : Array(Doma::Entry), ttl_by_id : Hash(Int64, Hash(String, Int64)), group_by_tag : Bool, check_existence : Bool)
      if group_by_tag
        # Object keyed by tag name; untagged entries land under "".
        grouped = {} of String => Array(Hash(String, JSON::Any))
        group_entries_by_tag(entries).each do |(tag_key, group)|
          grouped[tag_key] = group.map { |e| json_row(e, ttl_by_id, check_existence) }
        end
        puts grouped.to_json
      else
        payload = entries.map { |e| json_row(e, ttl_by_id, check_existence) }
        puts payload.to_json
      end
    end

    # Nothing matched: explain why (the empty_message), then layer on the
    # most useful next step — a typo/parent hint for a bogus tag, or the
    # first-run "add ." cue when the database is simply empty.
    private def report_empty(db : Doma::Database, tags : Array(String), query : String?)
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
    end

    # Print paths only, one per line (or NUL-terminated for `-0`). Each
    # value is *terminated* (not just separated) by the chosen delimiter,
    # matching `find -print0` semantics so xargs -0 sees a clean N-record
    # stream.
    private def emit_paths(entries : Array(Doma::Entry), group_by_tag : Bool, null_sep : Bool)
      sep = null_sep ? '\0' : '\n'
      if group_by_tag
        # Walk groups in display order so paths come out tag-sorted,
        # but dedup so an entry with N tags doesn't break xargs by
        # showing up N times.
        seen = Set(String).new
        group_entries_by_tag(entries).each do |(_, group)|
          group.each do |e|
            next unless seen.add?(e.path)
            STDOUT.print(e.path); STDOUT.print(sep)
          end
        end
      else
        entries.each { |e| STDOUT.print(e.path); STDOUT.print(sep) }
      end
    end

    # Default human-facing listing: the short_id / path / tags columns
    # (optionally grouped under tag headers), then the two footers that
    # surface what the default view hides — TTL-expired tags and missing
    # paths — alongside the flag that would reveal each.
    private def emit_text(db : Doma::Database, entries : Array(Doma::Entry), ttl_by_id : Hash(Int64, Hash(String, Int64)), group_by_tag : Bool, check_existence : Bool, include_expired : Bool)
      color = Doma::Logger.color_enabled?
      if group_by_tag
        group_entries_by_tag(entries).each do |(tag_key, group)|
          header = tag_key.empty? ? "(no tags)" : "##{tag_key}"
          header = header.colorize(:yellow).bold.to_s if color
          puts header
          group.each { |e| puts "  #{render_row(e, ttl_by_id, check_existence, color)}" }
        end
      else
        entries.each { |e| puts render_row(e, ttl_by_id, check_existence, color) }
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

      # Mirror the TTL footer for missing paths: when --check wasn't
      # passed, count entries whose path is gone and surface the flag
      # that would mark them. Without this, dead paths look identical
      # to live ones in the default listing — the user only finds out
      # after `cd` fails. Counting walks `entries` we already have, so
      # no extra DB round trip.
      unless check_existence
        gone = entries.count { |e| !Dir.exists?(e.path) }
        if gone > 0
          noun = gone == 1 ? "path is" : "paths are"
          STDERR.puts "  #{gone} #{noun} missing — pass --check to mark, or `doma prune --gone` to drop"
        end
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
        # Without an explicit override, refuse to silently auto-pick from
        # a non-interactive context: the README itself recommends
        # `cd "$(doma list -t crystal --pick)"`, and silently choosing
        # one of N matches there is a footgun (the script `cd`s into
        # a directory the user didn't intend). The user can opt back
        # into the previous behavior with `--first` or
        # `doma config set selector first`.
        if STDIN.tty?
          effective = Doma::Settings::SelectorMode::Builtin
        else
          first_tag = tags.first?
          context = first_tag ? "tag '#{first_tag}'" : "current filter"
          raise Doma::Error.new(
            "ambiguous --pick (#{context} matches #{items.size} directories) " \
            "and stdin is not a TTY",
            exit_code: 4,
            hint: "narrow the filter, or pass --first to take the most-recent match",
          )
        end
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
      Doma::Suggester.tag_hint_for(candidate, db.tag_names)
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
    #
    # SQLite's GLOB is a permissive `*`-anywhere matcher, including across
    # `/`. We re-tighten that to shell-glob semantics in Crystal — `*`
    # doesn't cross `/`, `**` does — by post-filtering with `TagGlob`.
    # The SQL still does the heavy lifting (tag join, sort, expiry
    # filter); the post-filter just trims false positives the strict
    # rules wouldn't accept.
    private def collect(db : Doma::Database, tags : Array(String), query : String?, sort : Doma::Database::SortBy, include_expired : Bool) : Array(Doma::Entry)
      base = if tags.empty?
               query ? db.search(query, include_expired: include_expired) : db.directories(sort: sort, include_expired: include_expired)
             else
               # Anchor on the first tag (gets the right `sort`/`include_expired`
               # treatment), then narrow by intersecting against each
               # additional tag's id set. Empty additional set short-circuits
               # to no matches without further DB work.
               first, *rest = tags
               anchor = strict_filter(db.directories(first, sort: sort, include_expired: include_expired), first)
               rest.each do |t|
                 break if anchor.empty?
                 ids = rest_tag_ids(db, t, include_expired)
                 anchor = anchor.select { |e| ids.includes?(e.id) }
               end
               anchor
             end

      return base if query.nil? || tags.empty?

      tagged_ids = base.map(&.id).to_set
      db.search(query, include_expired: include_expired).select { |e| tagged_ids.includes?(e.id) }
    end

    # Trim entries the SQL GLOB matched but our stricter rules would
    # reject (single `*` shouldn't cross `/`, etc.). No-op for plain tag
    # names — `TagGlob.match?` short-circuits to `==` there, but we skip
    # the per-entry loop entirely as a small optimization for the
    # common case.
    private def strict_filter(entries : Array(Doma::Entry), pattern : String) : Array(Doma::Entry)
      return entries unless pattern.includes?('*') || pattern.includes?('?')
      entries.select { |e| e.tags.any? { |t| Doma::TagGlob.match?(pattern, t) } }
    end

    # Id set for a tag used purely as an intersection filter (the second,
    # third, … `-t` in a multi-tag AND). For plain tag names we can ask
    # the database to hand us just the ids — no tag GROUP_CONCAT, no
    # entry hydration. For glob patterns the SQL GLOB is permissive
    # (crosses `/`), so we still pay the price of a full `directories()`
    # call to get each row's tag list back, then apply our stricter
    # match in Crystal. Worth re-investigating only if globbing in rest
    # position becomes a hot path.
    private def rest_tag_ids(db : Doma::Database, pattern : String, include_expired : Bool) : Set(Int64)
      if pattern.includes?('*') || pattern.includes?('?')
        strict_filter(db.directories(pattern, include_expired: include_expired), pattern).map(&.id).to_set
      else
        db.directory_ids_for_tag(pattern, include_expired: include_expired).to_set
      end
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

    # Bucket entries by tag name. An entry with N tags lands in N
    # buckets — the `--by tag` view is meant to show *every* tag's
    # contents, not pick a primary. Untagged entries collect under the
    # empty-string key so they can render under a "(no tags)" header
    # at the end.
    private def group_entries_by_tag(entries : Array(Doma::Entry)) : Array({String, Array(Doma::Entry)})
      buckets = {} of String => Array(Doma::Entry)
      entries.each do |e|
        if e.tags.empty?
          (buckets[""] ||= [] of Doma::Entry) << e
        else
          e.tags.each { |t| (buckets[t] ||= [] of Doma::Entry) << e }
        end
      end
      ordered = buckets.keys.reject(&.empty?).sort!.map { |k| {k, buckets[k]} }
      if untagged = buckets[""]?
        ordered << {"", untagged}
      end
      ordered
    end

    # Shared row formatter for the default (non-paths, non-json) output.
    # Extracted so the grouped renderer can prefix each line with two
    # spaces of indent without duplicating the column logic.
    private def render_row(e : Doma::Entry, ttl_by_id : Hash(Int64, Hash(String, Int64)), check_existence : Bool, color : Bool) : String
      short_str = color ? e.short_id.colorize(:dark_gray).to_s : e.short_id
      path_str = color ? e.path.colorize(:cyan).to_s : e.path
      ttl_map = ttl_by_id[e.id]? || EMPTY_TTL
      tags_str = e.tags.empty? ? "" : e.tags.map { |t| Doma::TagRenderer.render(t, ttl_map[t]?, color) }.join(' ')
      marker = ""
      if check_existence && !Dir.exists?(e.path)
        marker = color ? " #{"[gone]".colorize(:red)}" : " [gone]"
      end
      "#{short_str}  #{path_str}\t#{tags_str}#{marker}"
    end

    # Build one JSON row for an entry, matching the export/import schema.
    # Used by both the flat and grouped JSON render paths.
    private def json_row(e : Doma::Entry, ttl_by_id : Hash(Int64, Hash(String, Int64)), check_existence : Bool) : Hash(String, JSON::Any)
      row = {
        "short_id" => JSON::Any.new(e.short_id),
        "path"     => JSON::Any.new(e.path),
        "basename" => JSON::Any.new(e.basename),
        "tags"     => JSON::Any.new(e.tags.map { |t| JSON::Any.new(t) }),
      }
      if ttl_map = ttl_by_id[e.id]?
        row["expirations"] = JSON::Any.new(ttl_map.transform_values { |v| JSON::Any.new(v) })
      end
      row["exists"] = JSON::Any.new(Dir.exists?(e.path)) if check_existence
      row
    end

    # Pick the first tag the user typed that doesn't actually exist (and
    # isn't a glob) and propose the closest catalog name. Stops at one
    # hint to keep the noise floor low when several tags are bogus.
    # `tag_hint_for` covers two miss shapes: typo (Levenshtein) and
    # hierarchical parent (`-t work` when only `work/...` tags exist).
    private def typo_hint(db : Doma::Database, tags : Array(String)) : String?
      return if tags.empty?
      catalog = db.tag_names
      known = catalog.to_set
      tags.each do |t|
        next if t.includes?('*') || t.includes?('?')
        next if known.includes?(t)
        if hint = Doma::Suggester.tag_hint_for(t, catalog)
          return hint
        end
      end
      nil
    end
  end
end
