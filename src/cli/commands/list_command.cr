require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"

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
      tag : String? = nil
      json_mode = false
      paths_only = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma list [<query>] [-t TAG] [--json] [--paths]"
        p.on("-t TAG", "--tag=TAG", "Filter by exact tag") { |t| tag = t }
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("--paths", "Print paths only") { paths_only = true }
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

      db = Doma::Database.open
      begin
        entries = collect(db, tag, query)

        if json_mode
          payload = entries.map do |e|
            {
              "id"       => e.id,
              "path"     => e.path,
              "basename" => e.basename,
              "tags"     => e.tags,
            }
          end
          puts payload.to_json
          return
        end

        if entries.empty?
          STDERR.puts(empty_message(tag, query))
          return
        end

        if paths_only
          entries.each { |e| puts e.path }
          return
        end

        color = Doma::Logger.color_enabled?
        entries.each do |e|
          path_str = color ? e.path.colorize(:cyan).to_s : e.path
          tags_str = e.tags.empty? ? "" : e.tags.map { |t| color ? "##{t}".colorize(:yellow).to_s : "##{t}" }.join(' ')
          puts "#{path_str}\t#{tags_str}"
        end
      ensure
        db.close
      end
    end

    # Compose the two filters. Doing the intersection client-side keeps
    # the SQL straightforward — both `directories(tag)` and `search(query)`
    # already exist and are tested in isolation.
    private def collect(db : Doma::Database, tag : String?, query : String?) : Array(Doma::Entry)
      if tag && query
        tagged = db.directories(tag).map(&.id).to_set
        db.search(query).select { |e| tagged.includes?(e.id) }
      elsif tag
        db.directories(tag)
      elsif query
        db.search(query)
      else
        db.directories
      end
    end

    private def empty_message(tag : String?, query : String?) : String
      if tag && query
        "no matches for '#{query}' tagged '#{tag}'"
      elsif tag
        "no directories tagged '#{tag}'"
      elsif query
        "no matches for '#{query}'"
      else
        "no directories registered"
      end
    end
  end
end
