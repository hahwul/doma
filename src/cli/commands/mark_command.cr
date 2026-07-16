require "option_parser"
require "../../utils/errors"
require "../../utils/validator"
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
      ttl : String? = nil

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma mark [-p PATH] [--ttl DUR] (<tag> [<tag> ...] | -t TAG [-t TAG ...])"
        p.on("-p PATH", "--path=PATH", "Mark this path instead of the current directory") do |v|
          target_path = v
        end
        p.on("--ttl DUR", "Expire after DUR (e.g. 30m, 1h, 2w) instead of the 7d default") do |v|
          ttl = v
        end
        p.on("-t TAG", "--tag=TAG", "Add this tag (alias for positional; repeatable, comma-separated allowed)") do |t|
          Doma::Validator.split_tag_flag!(t).each { |part| tags << part }
        end
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Marks a directory with one or more temporary tags."
          STDOUT.puts "Each tag expires after 7 days by default. Equivalent to:"
          STDOUT.puts "    doma add <path> -t TAG ... --tmp"
          STDOUT.puts ""
          STDOUT.puts "Tags can be passed positionally (`mark work personal`)"
          STDOUT.puts "or via `-t TAG` (`mark -t work -t personal`); both forms"
          STDOUT.puts "may be mixed. Defaults to the current directory; pass"
          STDOUT.puts "-p PATH to mark elsewhere. Pass --ttl DUR for a custom"
          STDOUT.puts "lifetime (`mark spike --ttl 4h`) instead of the 7d default."
          exit 0
        end
        p.unknown_args do |before, after|
          tags.concat(before)
          tags.concat(after)
        end
      end
      parser.parse(args)

      if tags.empty?
        raise Doma::ValidationError.new(
          "mark requires at least one tag",
          hint: "usage: doma mark (<tag> [<tag> ...] | -t TAG [-t TAG ...])   (alias of add . -t … --tmp)"
        )
      end

      # Capture into a local so the closure-narrowing on `target_path`
      # propagates; Crystal won't infer non-nil from `target_path || "."`
      # when the source ivar is nilable.
      path = target_path
      forwarded = [path.nil? ? "." : path]
      # `--ttl DUR` overrides the 7d default; forward it verbatim so
      # `add` owns the duration grammar and validation (a bad `--ttl xyz`
      # surfaces the same error it would on `doma add`). Absent it, keep
      # the historical `--tmp` (7-day) shortcut.
      if dur = ttl
        forwarded << "--ttl" << dur
      else
        forwarded << "--tmp"
      end
      tags.each { |t| forwarded << "-t" << t }
      AddCommand.new.run(forwarded)
    end
  end
end
