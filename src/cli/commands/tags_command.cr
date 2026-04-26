require "option_parser"
require "json"
require "../../db/database"
require "../../utils/logger"

module Doma::CLI
  class TagsCommand
    def run(args : Array(String))
      json_mode = false
      names_only = false
      null_sep = false
      tree_mode = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma tags [--tree] [--json] [--names] [-0]"
        p.on("--tree", "Group tags hierarchically by '/' segments") { tree_mode = true }
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("--names", "Print tag names only") { names_only = true }
        # Same pattern as `doma list -0`: `-0` implies `--names` for
        # short pipeline invocations like `doma tags -0 | xargs -0 ...`.
        p.on("-0", "--print0", "Print tag names, NUL-separated (xargs -0)") do
          names_only = true
          null_sep = true
        end
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
          sep = null_sep ? '\0' : '\n'
          tags.each { |t| STDOUT.print(t.name); STDOUT.print(sep) }
          return
        end
        if tags.empty?
          STDERR.puts "no tags registered"
          return
        end

        if tree_mode
          render_tree(tags)
        else
          tags.each { |t| puts "#{t.name}\t#{t.count}" }
        end
      ensure
        db.close
      end
    end

    # Render tags grouped by `/` segments. Tag names act as paths:
    # `work/proj-a` and `work/proj-b` group under a synthetic `work/`
    # header. Bare tags (no `/`) sit at the root after the groups.
    private def render_tree(tags : Array(Doma::Database::TagSummary))
      color = Doma::Logger.color_enabled?
      grouped = {} of String => Array(Doma::Database::TagSummary)
      flat = [] of Doma::Database::TagSummary

      tags.each do |t|
        if t.name.includes?('/')
          prefix = t.name.split('/', 2).first
          (grouped[prefix] ||= [] of Doma::Database::TagSummary) << t
        else
          flat << t
        end
      end

      grouped.keys.sort!.each do |prefix|
        group = grouped[prefix]
        header = color ? "#{prefix}/".colorize(:cyan).bold.to_s : "#{prefix}/"
        puts "#{header}\t#{group.sum(&.count)}"
        group.each_with_index do |t, i|
          connector = (i == group.size - 1) ? "└─" : "├─"
          tail = t.name.split('/', 2)[1]? || t.name
          tail_str = color ? tail.colorize(:yellow).to_s : tail
          puts "  #{connector} #{tail_str}\t#{t.count}"
        end
      end

      puts "" unless grouped.empty? || flat.empty?
      flat.each { |t| puts "#{t.name}\t#{t.count}" }
    end
  end
end
