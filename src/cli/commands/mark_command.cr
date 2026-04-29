require "option_parser"
require "../../utils/errors"
require "./add_command"

module Doma::CLI
  # `doma mark <tag>` is a thin shortcut for the most common temporary
  # case: tag the current directory with a 7-day TTL. Underneath it
  # just constructs the equivalent `doma add . -t TAG --tmp` argv and
  # forwards to AddCommand — no separate code path means TTL behavior,
  # validation, and partial-success semantics stay identical.
  #
  # Multiple positional args are accepted and treated as additional
  # tags, mirroring `add -t a -t b -t c`. For custom TTL, fall back to
  # `add --ttl <DUR>`; this command is intentionally stripped down.
  class MarkCommand
    def run(args : Array(String))
      tags = [] of String
      target_path : String? = nil

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma mark [-p PATH] <tag> [<tag> ...]"
        p.on("-p PATH", "--path=PATH", "Mark this path instead of the current directory") do |v|
          target_path = v
        end
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Marks a directory with one or more temporary tags."
          STDOUT.puts "Each tag expires after 7 days. Equivalent to:"
          STDOUT.puts "    doma add <path> -t TAG ... --tmp"
          STDOUT.puts ""
          STDOUT.puts "Defaults to the current directory; pass -p PATH to mark"
          STDOUT.puts "elsewhere. For a custom TTL, use `doma add --ttl`."
          exit 0
        end
        p.unknown_args do |before, after|
          tags.concat(before)
          tags.concat(after)
        end
      end
      parser.parse(args)

      raise Doma::ValidationError.new("at least one tag is required") if tags.empty?

      # Capture into a local so the closure-narrowing on `target_path`
      # propagates; Crystal won't infer non-nil from `target_path || "."`
      # when the source ivar is nilable.
      path = target_path
      forwarded = [path.nil? ? "." : path, "--tmp"]
      tags.each { |t| forwarded << "-t" << t }
      AddCommand.new.run(forwarded)
    end
  end
end
