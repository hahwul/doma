require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/time_formatter"

module Doma::CLI
  # Quick "what's on the cutting board" summary: total counts, hottest tags,
  # most recently added directories. Designed for at-a-glance use; a JSON
  # form is provided for scripting.
  class StatsCommand
    def run(args : Array(String))
      json_mode = false
      top_n = 10
      recent_n = 5
      used_n = 5
      group_prefix = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma stats [--top N] [--recent N] [--used N] [--group-by-prefix] [--json]"
        p.on("--top N", "Show the top N tags (default 10)") do |n|
          top_n = parse_count("--top", n)
        end
        p.on("--recent N", "Show the N most recently *added* paths (default 5)") do |n|
          recent_n = parse_count("--recent", n)
        end
        p.on("--used N", "Show the N most recently *used* paths (default 5)") do |n|
          used_n = parse_count("--used", n)
        end
        p.on("--group-by-prefix", "Roll the top-tags chart up by the first '/' segment") do
          group_prefix = true
        end
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
      parser.parse(args)

      db = Doma::Database.open
      begin
        # When rolling up by prefix, ask the database for *all* tags
        # before we collapse — otherwise a `top_n` truncation could
        # silently drop a leaf that would have changed a parent's total.
        # Cheap enough; tag tables stay tiny in real use.
        effective_top_n = group_prefix ? Int32::MAX : top_n
        stats = db.stats(top_n: effective_top_n, recent_n: recent_n, used_n: used_n)

        rendered_top = group_prefix ? roll_up_by_prefix(stats.top_tags, top_n) : stats.top_tags

        if json_mode
          payload = {
            "total_directories" => stats.total_directories,
            "total_tags"        => stats.total_tags,
            "top_tags"          => rendered_top.map { |t| {"name" => t.name, "count" => t.count} },
            "recent"            => stats.recent.map { |r| {"path" => r[:path], "created_at" => r[:created_at]} },
            "most_used"         => stats.most_used.map { |r| {"path" => r[:path], "last_used_at" => r[:last_used_at]} },
          }
          puts payload.to_json
          return
        end

        render_text(stats, rendered_top, group_prefix)
      ensure
        db.close
      end
    end

    private def parse_count(flag : String, raw : String) : Int32
      n = raw.to_i?
      raise Doma::ValidationError.new("#{flag} must be a non-negative integer, got '#{raw}'") if n.nil? || n < 0
      n
    end

    # Collapse hierarchical tags by their first `/` segment. `crystal/web`,
    # `crystal/cli`, `crystal/lib` all roll up under `crystal/*` with the
    # summed count. Bare tags (no `/`) stay as themselves. The chart
    # otherwise drowns out cohesive group totals — `crystal:3` next to
    # `a/b/c/d/e/f:1` and `bookmark:1` doesn't help a user gauge what
    # they actually work on.
    private def roll_up_by_prefix(tags : Array(Doma::Database::TagSummary), limit : Int32) : Array(Doma::Database::TagSummary)
      buckets = {} of String => Int64
      tags.each do |t|
        key = if idx = t.name.index('/')
                "#{t.name[0...idx]}/*"
              else
                t.name
              end
        buckets[key] = (buckets[key]? || 0_i64) + t.count
      end
      buckets.to_a
        .sort_by! { |pair| {-pair[1], pair[0]} }
        .first(limit)
        .map { |pair| Doma::Database::TagSummary.new(pair[0], pair[1]) }
    end

    private def render_text(stats : Doma::Database::Stats, top_tags : Array(Doma::Database::TagSummary), group_prefix : Bool)
      color = Doma::Logger.color_enabled?
      label = ->(s : String) { color ? s.colorize(:cyan).bold.to_s : s }

      puts "#{label.call("Directories:")} #{stats.total_directories}"
      puts "#{label.call("Tags:       ")} #{stats.total_tags}"
      puts ""

      heading = group_prefix ? "Top tags (grouped by /):" : "Top tags:"
      if top_tags.empty?
        puts label.call(heading) + " (none)"
      else
        puts label.call(heading)
        max = top_tags.first.count
        top_tags.each do |tag|
          bar_width = max == 0 ? 0 : ((tag.count.to_f / max) * 24).to_i
          bar = "█" * bar_width
          tag_label = color ? "##{tag.name}".colorize(:yellow).to_s : "##{tag.name}"
          puts "  #{tag_label.ljust(24)} #{tag.count.to_s.rjust(4)}  #{bar}"
        end
      end

      puts ""
      if stats.recent.empty?
        puts label.call("Recent:") + " (none)"
      else
        puts label.call("Recent:")
        stats.recent.each do |entry|
          ts = Doma::TimeFormatter.absolute(entry[:created_at])
          path_str = color ? entry[:path].colorize(:cyan).to_s : entry[:path]
          puts "  #{ts}  #{path_str}"
        end
      end

      puts ""
      if stats.most_used.empty?
        puts label.call("Most used:") + " (run `doma cd` to start tracking)"
      else
        puts label.call("Most used:")
        stats.most_used.each do |entry|
          ts = Doma::TimeFormatter.absolute(entry[:last_used_at])
          path_str = color ? entry[:path].colorize(:cyan).to_s : entry[:path]
          puts "  #{ts}  #{path_str}"
        end
      end
    end
  end
end
