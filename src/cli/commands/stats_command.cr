require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"

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

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma stats [--top N] [--recent N] [--used N] [--json]"
        p.on("--top N", "Show the top N tags (default 10)") do |n|
          top_n = parse_count("--top", n)
        end
        p.on("--recent N", "Show the N most recently *added* paths (default 5)") do |n|
          recent_n = parse_count("--recent", n)
        end
        p.on("--used N", "Show the N most recently *used* paths (default 5)") do |n|
          used_n = parse_count("--used", n)
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
        stats = db.stats(top_n: top_n, recent_n: recent_n, used_n: used_n)

        if json_mode
          payload = {
            "total_directories" => stats.total_directories,
            "total_tags"        => stats.total_tags,
            "top_tags"          => stats.top_tags.map { |t| {"name" => t.name, "count" => t.count} },
            "recent"            => stats.recent.map { |r| {"path" => r[:path], "created_at" => r[:created_at]} },
            "most_used"         => stats.most_used.map { |r| {"path" => r[:path], "last_used_at" => r[:last_used_at]} },
          }
          puts payload.to_json
          return
        end

        render_text(stats)
      ensure
        db.close
      end
    end

    private def parse_count(flag : String, raw : String) : Int32
      n = raw.to_i?
      raise Doma::ValidationError.new("#{flag} must be a non-negative integer, got '#{raw}'") if n.nil? || n < 0
      n
    end

    private def render_text(stats : Doma::Database::Stats)
      color = Doma::Logger.color_enabled?
      label = ->(s : String) { color ? s.colorize(:cyan).bold.to_s : s }

      puts "#{label.call("Directories:")} #{stats.total_directories}"
      puts "#{label.call("Tags:       ")} #{stats.total_tags}"
      puts ""

      if stats.top_tags.empty?
        puts label.call("Top tags:") + " (none)"
      else
        puts label.call("Top tags:")
        max = stats.top_tags.first.count
        stats.top_tags.each do |tag|
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
          ts = Time.unix(entry[:created_at]).to_local.to_s("%Y-%m-%d %H:%M")
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
          ts = Time.unix(entry[:last_used_at]).to_local.to_s("%Y-%m-%d %H:%M")
          path_str = color ? entry[:path].colorize(:cyan).to_s : entry[:path]
          puts "  #{ts}  #{path_str}"
        end
      end
    end
  end
end
