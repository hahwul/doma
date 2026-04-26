require "option_parser"
require "json"
require "../../db/database"
require "../../utils/logger"

module Doma::CLI
  class TagsCommand
    def run(args : Array(String))
      json_mode = false
      names_only = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma tags [--json] [--names]"
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("--names", "Print tag names only") { names_only = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
      parser.parse(args)

      db = Doma::Database.open
      begin
        tags = db.all_tags
        if json_mode
          puts tags.map { |t| {"name" => t.name, "count" => t.count} }.to_json
          return
        end
        if names_only
          tags.each { |t| puts t.name }
          return
        end
        if tags.empty?
          STDERR.puts "no tags registered"
          return
        end
        tags.each { |t| puts "#{t.name}\t#{t.count}" }
      ensure
        db.close
      end
    end
  end
end
