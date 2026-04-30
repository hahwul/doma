require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../utils/duration"
require "../../utils/errors"
require "../../utils/logger"
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
      canonical = Doma::Validator.canonicalize(raw)

      db = Doma::Database.open
      begin
        info = db.find_path_info(canonical)
        unless info
          # Treat "not registered" as a NotFound (exit 3), matching
          # `list --pick` on a missing tag. Surface a hint that points
          # at `add` so the user can convert the question into the next
          # action without re-typing the path.
          raise Doma::NotFoundError.new(
            "not registered: #{canonical}",
            hint: "to register it, run: doma add #{raw}"
          )
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

    private def render_json(info : Doma::Database::PathInfo, tags : Array(String), ttl_map : Hash(String, Int64), exists : Bool)
      payload = {
        "id"           => JSON::Any.new(info.id),
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
      kv "exists", exists ? "yes" : color ? "NO".colorize(:red).to_s : "NO"

      if tags.empty?
        kv "tags", "(none)"
      else
        rendered = tags.map { |t| render_tag(t, ttl_map[t]?, color) }.join(' ')
        kv "tags", rendered
      end

      kv "added", format_time(info.created_at)
      kv "last used", info.last_used_at == 0 ? "never" : format_time(info.last_used_at)

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

    private def render_tag(tag : String, expires_at : Int64?, color : Bool) : String
      base = color ? "##{tag}".colorize(:yellow).to_s : "##{tag}"
      return base unless expires_at
      remaining = Doma::Duration.humanize_remaining(expires_at)
      suffix = "~#{remaining}"
      return "#{base}#{suffix}" unless color
      tinted = remaining == "expired" ? suffix.colorize(:red) : suffix.colorize(:dark_gray)
      "#{base}#{tinted}"
    end

    # ISO-ish local-time format. Stable, sortable, and unambiguous —
    # which `Time#to_s` default isn't (locale-dependent on some libcs).
    private def format_time(epoch : Int64) : String
      Time.unix(epoch).to_local.to_s("%Y-%m-%d %H:%M")
    end
  end
end
