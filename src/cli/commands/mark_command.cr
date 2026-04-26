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

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma mark <tag> [<tag> ...]"
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Marks the current directory with one or more temporary tags."
          STDOUT.puts "Each tag expires after 7 days. Equivalent to:"
          STDOUT.puts "    doma add . -t TAG ... --tmp"
          STDOUT.puts ""
          STDOUT.puts "For a custom TTL or different path, use `doma add` directly."
          exit 0
        end
        p.unknown_args do |before, after|
          tags.concat(before)
          tags.concat(after)
        end
      end
      parser.parse(args)

      raise Doma::ValidationError.new("at least one tag is required") if tags.empty?

      forwarded = [".", "--tmp"] of String
      tags.each { |t| forwarded << "-t" << t }
      AddCommand.new.run(forwarded)
    end
  end
end
