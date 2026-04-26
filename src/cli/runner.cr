require "colorize"
require "../utils/errors"
require "../utils/logger"
require "../utils/suggester"
require "./commands/add_command"
require "./commands/rm_command"
require "./commands/list_command"
require "./commands/tags_command"
require "./commands/cd_command"
require "./commands/run_command"
require "./commands/export_command"
require "./commands/import_command"
require "./commands/rename_command"
require "./commands/stats_command"
require "./commands/setup_command"
require "./commands/move_command"

module Doma
  module CLI
    class Runner
      KNOWN_COMMANDS = %w[
        add rm remove list ls tags rename move mv
        stats cd run export import setup
        version help -V --version -h --help
      ]

      def run(args : Array(String) = ARGV.dup)
        # Pull global flags out of argv before subcommand dispatch — every
        # command honors them without needing per-command wiring, and
        # they don't leak into OptionParser as InvalidOption.
        Runner.apply_globals!(args)

        if args.empty?
          print_help
          return
        end

        command = args.shift
        case command
        when "-V", "--version", "version"
          puts Doma::VERSION
        when "-h", "--help", "help"
          print_help
        when "add"
          AddCommand.new.run(args)
        when "rm", "remove"
          RmCommand.new.run(args)
        when "list", "ls"
          ListCommand.new.run(args)
        when "tags"
          TagsCommand.new.run(args)
        when "cd"
          CdCommand.new.run(args)
        when "run"
          RunCommand.new.run(args)
        when "export"
          ExportCommand.new.run(args)
        when "import"
          ImportCommand.new.run(args)
        when "rename"
          RenameCommand.new.run(args)
        when "move", "mv"
          MoveCommand.new.run(args)
        when "stats"
          StatsCommand.new.run(args)
        when "setup"
          SetupCommand.new.run(args)
        else
          Doma::Logger.error "unknown command '#{command}'"
          if suggestion = Doma::Suggester.suggest(command, KNOWN_COMMANDS)
            STDERR.puts "  Did you mean '#{suggestion}'?"
          end
          STDERR.puts "Run 'doma --help' to see all commands."
          exit 1
        end
      rescue ex : Doma::Error
        Doma::Logger.error ex.message || "unknown error"
        if hint = ex.hint
          STDERR.puts "  #{hint}"
        end
        exit ex.exit_code
      rescue ex : OptionParser::InvalidOption | OptionParser::MissingOption
        Doma::Logger.error ex.message || "invalid option"
        exit 1
      rescue ex : Exception
        Doma::Logger.error "internal error: #{ex.message}"
        exit 1
      end

      # Strip global flags from argv in-place and apply them to the Logger.
      # Called before the subcommand sees the args so commands don't need
      # to whitelist `-q` etc. in their own OptionParsers.
      def self.apply_globals!(argv : Array(String))
        argv.reject! do |arg|
          case arg
          when "-q", "--quiet"
            Doma::Logger.quiet = true
            true
          when "-v", "--verbose", "--debug"
            Doma::Logger.debug = true
            true
          when "--no-color"
            Doma::Logger.no_color = true
            true
          when "--color"
            Doma::Logger.no_color = false
            true
          else
            false
          end
        end
      end

      # Order is preserved from the previous grouped layout (paths →
      # tags → browse → execute → snapshot → setup) so muscle memory and
      # docs continue to make sense; only the visual grouping is gone.
      COMMAND_LISTING = [
        {"add [<path>]", "Register a path (defaults to .) with tags"},
        {"rm <path>", "Remove tag(s) or the path itself"},
        {"move <old> <new>", "Move a registered path (tags carry over)"},
        {"tags", "List all tags with counts"},
        {"rename <old> <new>", "Rename or merge a tag"},
        {"list [<query>] [-t TAG]", "List/search directories (--json, --paths)"},
        {"cd [<tag>]", "Resolve a directory (interactive picker)"},
        {"stats", "Top tags + recently added paths"},
        {"run <tag> -- <cmd>", "Run a command in every tagged directory"},
        {"export", "Dump the database (--json | --yaml)"},
        {"import <file>", "Load a snapshot (--merge | --replace)"},
        {"setup <action>", "install / init / doctor — see `doma setup --help`"},
        {"version | help", "Show version / this help"},
      ]

      private def print_help
        color = Doma::Logger.color_enabled?
        brand = color ? "doma".colorize(:cyan).bold.to_s : "doma"
        slogan = "Put your directories on the cutting board"

        puts ""
        puts "#{brand} v#{Doma::VERSION}  —  #{slogan}"
        puts ""
        puts "Usage: doma <command> [options]"
        puts ""
        puts "Commands:"
        COMMAND_LISTING.each do |row|
          name, desc = row
          puts "  #{name.ljust(24)} #{desc}"
        end
        puts ""
        puts "Global flags:"
        puts "  -q, --quiet             Suppress success/info output"
        puts "  -v, --verbose, --debug  Print debug traces to stderr"
        puts "      --no-color, --color Force color off / on"
        puts ""
        puts "Make `doma cd` actually change directory:"
        puts "  doma setup install                # auto-append to your shell's rc file"
        puts "  eval \"$(doma setup init zsh)\"     # or do it yourself"
        puts ""
        puts "Without the wrapper, `doma cd` only prints the resolved path —"
        puts "use `cd \"$(doma cd <tag>)\"` to apply it manually."
        puts ""
        puts "Pipelines:"
        puts "  doma list -t crystal --paths            # one path per line"
        puts "  doma list -t crystal -0 | xargs -0 ...  # NUL-safe for spaces"
        puts "  doma list -t crystal --json | jq        # structured"
        puts "  doma tags --names                       # just tag names"
        puts ""
      end
    end
  end
end
