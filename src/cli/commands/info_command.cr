require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../services/trash"
require "../../utils/duration"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/short_id_resolver"
require "../../utils/tag_renderer"
require "../../utils/time_formatter"
require "../../utils/validator"

module Doma::CLI
  # Detail view for a single registered path. Defaults to cwd because
  # the typical question — "did I tag this directory? with what?" —
  # is asked from inside it. Without `info`, the user has to fall back
  # to `list <substring>` (noisy, can match other paths) or
  # `list --json | jq` (heavy). This is the dedicated single-entry
  # lookup that complements `list`'s set view.
  class InfoCommand
    def run(args : Array(String))
      json_mode = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma info [<path>] [--json]"
        p.on("--json", "Output as JSON") { json_mode = true }
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

      raw = positional.first? || "."

      db = Doma::Database.open
      begin
        # Three input shapes, resolution order:
        #   1. short_id-shaped (hex, no path separators) → resolve via
        #      ShortIdResolver. Mirrors `rm <id>` / `trash restore <id>`
        #      so the same 7-char id from `list` output works everywhere.
        #   2. path-shaped → canonicalize and look up directly.
        #   3. not registered + path-shaped → check trash so a recent
        #      `rm` doesn't leave the user staring at "not registered"
        #      with no clue the entry is recoverable.
        canonical, info = resolve_target(db, raw)

        unless info
          if !Doma::ShortIdResolver.looks_like?(raw)
            # Bare-name fallback: when the user types `doma info doma`,
            # they almost certainly mean "show me the entry whose path
            # or tag contains `doma`", not "look up `<cwd>/doma` as a
            # filesystem path". Mirror `list <query>` here when the
            # input has no path-like markers (no `/`, `.`, or `~`),
            # didn't resolve as a short_id, and isn't `.` (which always
            # means cwd). Exactly one hit → show it. Multiple →
            # disambiguate with short_ids so the user can re-issue.
            if name_like?(raw) && (info = resolve_by_search(db, raw))
              tags = db.tags_for(info.id)
              ttl_map = db.tag_expirations(info.id, include_past: true)
              exists = Dir.exists?(info.path)
              if json_mode
                render_json(info, tags, ttl_map, exists)
              else
                render_text(info, tags, ttl_map, exists, raw)
              end
              return
            end

            if trashed = Doma::Trash.find_by_path(canonical)
              raise Doma::NotFoundError.new(
                "not registered: #{canonical}",
                hint: "in trash (id #{trashed.short_id[0..6]}). " \
                      "Restore: doma trash restore #{trashed.short_id[0..6]}"
              )
            end
            raise Doma::NotFoundError.new(
              "not registered: #{canonical}",
              hint: "to register it, run: doma add #{raw}"
            )
          end
          # short_id input that didn't resolve: caller-friendly message
          # without an `add` hint (the user typed an id, not a path).
          raise Doma::NotFoundError.new("no entry with short_id '#{raw}'")
        end

        tags = db.tags_for(info.id)
        # Show every TTL — including past ones — so an expired tag
        # doesn't silently disappear from the detail view. The render
        # layer marks "expired" rows distinctly.
        ttl_map = db.tag_expirations(info.id, include_past: true)
        exists = Dir.exists?(info.path)

        if json_mode
          render_json(info, tags, ttl_map, exists)
        else
          render_text(info, tags, ttl_map, exists, raw)
        end
      ensure
        db.close
      end
    end

    # Returns {canonical_path, PathInfo?}. PathInfo is nil if not
    # registered; canonical_path is set in both cases (used by the
    # trash fallback and the not-found message).
    private def resolve_target(db : Doma::Database, raw : String) : {String, Doma::Database::PathInfo?}
      if File.exists?(raw) || Dir.exists?(raw)
        canonical = Doma::Validator.canonicalize(raw)
        return {canonical, db.find_path_info(canonical)}
      end

      if Doma::ShortIdResolver.looks_like?(raw)
        if path = Doma::ShortIdResolver.resolve(db, raw)
          return {path, db.find_path_info(path)}
        end
        # Non-resolving short_id-shaped input falls through with an
        # empty path so the caller can raise a clean "no entry with
        # short_id" error — there's nothing to canonicalize.
        return {raw, nil}
      end

      canonical = Doma::Validator.canonicalize(raw)
      {canonical, db.find_path_info(canonical)}
    end

    # True for inputs the user clearly didn't mean as a filesystem
    # path: no path separators, no parent/relative markers. Anchors
    # the substring-search fallback so `info <abs_path>` for a
    # missing path still produces "not registered" instead of being
    # silently broadened.
    private def name_like?(raw : String) : Bool
      return false if raw.empty? || raw == "."
      !raw.includes?('/') && !raw.includes?('.') && !raw.includes?('~')
    end

    # Substring fallback for bare-name `info` inputs. One match → show
    # it. Multiple matches raise a ValidationError with a candidate
    # list; the user picks one and re-issues with the short_id (which
    # is unambiguous). No matches → return nil so the caller falls
    # through to the existing not-registered + trash hint flow.
    private def resolve_by_search(db : Doma::Database, query : String) : Doma::Database::PathInfo?
      hits = db.search(query)
      return if hits.empty?

      if hits.size == 1
        return db.find_path_info(hits.first.path)
      end

      lines = hits.first(8).map do |e|
        tag_str = e.tags.empty? ? "" : "\t##{e.tags.join(" #")}"
        "  #{e.short_id}  #{e.path}#{tag_str}"
      end
      more = hits.size > 8 ? "\n  ... and #{hits.size - 8} more" : ""
      raise Doma::ValidationError.new(
        "multiple matches for '#{query}':\n#{lines.join("\n")}#{more}",
        "pick one with `doma info <short_id>` or narrow with `doma list #{query}`"
      )
    end

    private def render_json(info : Doma::Database::PathInfo, tags : Array(String), ttl_map : Hash(String, Int64), exists : Bool)
      payload = {
        "short_id"     => JSON::Any.new(info.short_id),
        "path"         => JSON::Any.new(info.path),
        "basename"     => JSON::Any.new(info.basename),
        "tags"         => JSON::Any.new(tags.map { |t| JSON::Any.new(t) }),
        "created_at"   => JSON::Any.new(info.created_at),
        "last_used_at" => JSON::Any.new(info.last_used_at),
        "exists"       => JSON::Any.new(exists),
      } of String => JSON::Any
      unless ttl_map.empty?
        payload["expirations"] = JSON::Any.new(ttl_map.transform_values { |v| JSON::Any.new(v) })
      end
      puts payload.to_json
    end

    private def render_text(info : Doma::Database::PathInfo, tags : Array(String), ttl_map : Hash(String, Int64), exists : Bool, raw : String)
      color = Doma::Logger.color_enabled?

      # Header: short_id (dim) + canonical path (cyan), so the eye lands
      # on the path while the id stays available for copy-paste.
      short_str = color ? info.short_id.colorize(:dark_gray).to_s : info.short_id
      path_str = color ? info.path.colorize(:cyan).to_s : info.path
      puts "#{short_str}  #{path_str}"

      kv "basename", info.basename
      exists_label = if exists
                       "yes"
                     elsif color
                       "NO".colorize(:red).to_s
                     else
                       "NO"
                     end
      kv "exists", exists_label

      if tags.empty?
        kv "tags", "(none)"
      else
        rendered = tags.map { |t| Doma::TagRenderer.render(t, ttl_map[t]?, color) }.join(' ')
        kv "tags", rendered
      end

      # Show absolute + relative side-by-side. Absolute is the source
      # of truth; relative ("3d ago") is what the eye actually wants
      # for "how stale is this entry?" — the question users actually
      # ask. Same compact `Nu` form `Duration.humanize_remaining` uses,
      # for symmetry across the suite.
      kv "added", "#{Doma::TimeFormatter.absolute(info.created_at)}  (#{Doma::TimeFormatter.relative_past(info.created_at, color)})"
      if info.last_used_at == 0
        kv "last used", "never"
      else
        kv "last used", "#{Doma::TimeFormatter.absolute(info.last_used_at)}  (#{Doma::TimeFormatter.relative_past(info.last_used_at, color)})"
      end

      # If the user typed a non-canonical form (relative path, symlink,
      # trailing slash), show what we resolved it to so they know which
      # entry they're looking at — silently rewriting the input is a UX
      # trap when paths look almost-but-not-identical.
      canonical = info.path
      if raw != canonical && raw != "."
        STDERR.puts "  (resolved '#{raw}' → '#{canonical}')"
      end
    end

    private def kv(key : String, value : String)
      puts "  #{key.ljust(11)} #{value}"
    end
  end
end
