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

    # Tag names act as paths: `work/proj/frontend` and `work/proj/backend`
    # nest under `work/proj/` which nests under `work/`. The previous
    # implementation only split once (`split('/', 2)`), so deeper
    # hierarchies were rendered half-flat. This recurses to the full
    # depth and aggregates counts at every internal node.
    private class TreeNode
      property children : Hash(String, TreeNode)
      property leaves : Array(Doma::Database::TagSummary)

      def initialize
        @children = {} of String => TreeNode
        @leaves = [] of Doma::Database::TagSummary
      end

      # Sum of every leaf below this node, regardless of depth. Used for
      # the bracketed group-total in the rendered header.
      def total_count : Int64
        sub = @children.each_value.sum(&.total_count)
        sub + @leaves.sum(&.count)
      end
    end

    private def render_tree(tags : Array(Doma::Database::TagSummary))
      color = Doma::Logger.color_enabled?
      root = TreeNode.new
      flat = [] of Doma::Database::TagSummary

      tags.each do |t|
        if t.name.includes?('/')
          insert_node(root, t.name.split('/'), t)
        else
          flat << t
        end
      end

      sorted_groups = root.children.keys.sort!
      sorted_groups.each_with_index do |prefix, idx|
        node = root.children[prefix]
        header = color ? "#{prefix}/".colorize(:cyan).bold.to_s : "#{prefix}/"
        puts "#{header}\t#{node.total_count}"
        render_subtree(node, "  ", color)
        # Blank line between top-level groups so the eye lands on each
        # cluster instead of one continuous wall.
        puts "" if idx < sorted_groups.size - 1
      end

      puts "" unless root.children.empty? || flat.empty?
      flat.each { |t| puts "#{t.name}\t#{t.count}" }
    end

    private def insert_node(parent : TreeNode, segments : Array(String), tag : Doma::Database::TagSummary)
      head, *rest = segments
      if rest.empty?
        # Leaf: this segment is the final piece of the tag name.
        # `head` may collide with an internal node (e.g. `work` exists
        # both as a bare tag and as a parent of `work/proj`). We attach
        # it to the parent's leaves keyed by full name; the renderer
        # treats children + leaves as siblings in display order.
        parent.leaves << tag
      else
        node = parent.children[head] ||= TreeNode.new
        insert_node(node, rest, tag)
      end
    end

    private def render_subtree(node : TreeNode, indent : String, color : Bool)
      # Render in stable order: subgroups (alphabetical) first, then
      # leaves. The connector for the very last sibling switches from
      # `├─` to `└─` and the indent for that branch drops the vertical
      # bar, matching standard `tree(1)` output.
      group_keys = node.children.keys.sort!
      leaves = node.leaves.sort_by(&.name)
      total_siblings = group_keys.size + leaves.size

      idx = 0
      group_keys.each do |key|
        idx += 1
        last = idx == total_siblings
        connector = last ? "└─" : "├─"
        child = node.children[key]
        header = color ? "#{key}/".colorize(:cyan).to_s : "#{key}/"
        puts "#{indent}#{connector} #{header}\t#{child.total_count}"
        render_subtree(child, indent + (last ? "   " : "│  "), color)
      end

      leaves.each do |leaf|
        idx += 1
        last = idx == total_siblings
        connector = last ? "└─" : "├─"
        # Show only the final segment in the tree; the parent path is
        # already implied by the indentation.
        tail = leaf.name.split('/').last
        tail_str = color ? tail.colorize(:yellow).to_s : tail
        puts "#{indent}#{connector} #{tail_str}\t#{leaf.count}"
      end
    end
  end
end
