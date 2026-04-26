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
      null_sep = false
      check_existence = false
      include_expired = false
      sort = Doma::Database::SortBy::Path
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma list [<query>] [-t TAG] [--by path|recent] [--check] [--include-expired] [--json] [--paths] [-0]"
        p.on("-t TAG", "--tag=TAG", "Filter by exact tag") { |t| tag = t }
        p.on("--by SORT", "Sort by 'path' (default) or 'recent'") do |val|
          sort = case val
                 when "path" then Doma::Database::SortBy::Path
                 when "recent",
                      "used",
                      "recency" then Doma::Database::SortBy::Recent
                 else
                   raise Doma::ValidationError.new("--by must be 'path' or 'recent', got '#{val}'")
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
        entries = collect(db, tag, query, sort, include_expired)

        if json_mode
          payload = entries.map do |e|
            row = {
              "id"       => JSON::Any.new(e.id),
              "short_id" => JSON::Any.new(e.short_id),
              "path"     => JSON::Any.new(e.path),
              "basename" => JSON::Any.new(e.basename),
              "tags"     => JSON::Any.new(e.tags.map { |t| JSON::Any.new(t) }),
            }
            row["exists"] = JSON::Any.new(Dir.exists?(e.path)) if check_existence
            row
          end
          puts payload.to_json
          return
        end

        if entries.empty?
          STDERR.puts(empty_message(tag, query))
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
          tags_str = e.tags.empty? ? "" : e.tags.map { |t| color ? "##{t}".colorize(:yellow).to_s : "##{t}" }.join(' ')
          marker = ""
          if check_existence && !Dir.exists?(e.path)
            marker = color ? " #{"[gone]".colorize(:red)}" : " [gone]"
          end
          puts "#{short_str}  #{path_str}\t#{tags_str}#{marker}"
        end
      ensure
        db.close
      end
    end

    # Compose the two filters. Doing the intersection client-side keeps
    # the SQL straightforward — both `directories(tag)` and `search(query)`
    # already exist and are tested in isolation.
    private def collect(db : Doma::Database, tag : String?, query : String?, sort : Doma::Database::SortBy, include_expired : Bool) : Array(Doma::Entry)
      if tag && query
        tagged = db.directories(tag, sort: sort, include_expired: include_expired).map(&.id).to_set
        db.search(query).select { |e| tagged.includes?(e.id) }
      elsif tag
        db.directories(tag, sort: sort, include_expired: include_expired)
      elsif query
        db.search(query)
      else
        db.directories(sort: sort, include_expired: include_expired)
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
