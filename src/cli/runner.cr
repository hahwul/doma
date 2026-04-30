require "colorize"
require "../utils/errors"
require "../utils/logger"
require "../utils/runtime"
require "../utils/suggester"
require "./commands/add_command"
require "./commands/mark_command"
require "./commands/rm_command"
require "./commands/prune_command"
require "./commands/list_command"
require "./commands/info_command"
require "./commands/tags_command"
require "./commands/run_command"
require "./commands/export_command"
require "./commands/import_command"
require "./commands/rename_command"
require "./commands/stats_command"
require "./commands/setup_command"
require "./commands/doctor_command"
require "./commands/move_command"
require "./commands/config_command"
require "./commands/trash_command"

module Doma
  module CLI
    class Runner
      KNOWN_COMMANDS = %w[
        add mark rm remove prune list ls info tags rename move mv
        stats run export import setup doctor config trash
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
        when "-h", "--help"
          print_help
        when "help"
          # `doma help <cmd>` → route to that subcommand's own --help so
          # users see the usage line without the global banner. Bare
          # `doma help` falls through to the orientation page.
          if args.empty?
            print_help
          else
            sub = args.shift
            run([sub, "--help"])
          end
        when "add"
          AddCommand.new.run(args)
        when "mark"
          MarkCommand.new.run(args)
        when "rm", "remove"
          RmCommand.new.run(args)
        when "prune"
          PruneCommand.new.run(args)
        when "list", "ls"
          ListCommand.new.run(args)
        when "info"
          InfoCommand.new.run(args)
        when "tags"
          TagsCommand.new.run(args)
        when "cd"
          # The binary doesn't ship a `cd` subcommand — directory change
          # has to happen in the parent shell, which a child process
          # can't do. The shell function installed by `doma setup install`
          # provides `doma cd <tag>` by calling `doma list -t <tag> --pick`
          # and running `cd` itself.
          Doma::Logger.error "`doma cd` is provided by the shell wrapper, not the binary"
          STDERR.puts "  Run `doma setup install` to enable it (or `eval \"$(doma setup init <shell>)\"`)."
          STDERR.puts "  In a script, use: cd \"$(doma list -t <tag> --pick)\""
          exit 1
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
        when "doctor"
          DoctorCommand.new.run(args)
        when "config"
          ConfigCommand.new.run(args)
        when "trash"
          TrashCommand.new.run(args)
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
        # `cmd | head -1` and friends close the pipe after one line —
        # our subsequent puts then raises EPIPE. That's a clean
        # consumer-disconnect, not an error worth shouting about.
        # Convention: 128 + SIGPIPE(13) = 141.
        exit 141 if ex.message.try(&.includes?("Broken pipe"))
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
          when "-y", "--yes"
            Doma::Runtime.assume_yes = true
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
        {"mark <tag> ...", "Tag cwd with temporary (7d) tags  (alias of add . -t … --tmp)"},
        {"rm <path>", "Remove tag(s) or the path itself"},
        {"prune --gone|--expired", "Bulk-delete missing paths or expired tags"},
        {"move <old> <new>", "Move a registered path (tags carry over)"},
        {"tags", "List all tags with counts"},
        {"rename <old> <new>", "Rename or merge a tag"},
        {"list [<query>] [-t TAG]", "List/search directories (--json, --paths, --pick)"},
        {"info [<path>]", "Show one entry's tags / TTLs / last-used (default: cwd)"},
        {"stats", "Top tags + recently added paths"},
        {"run <tag> -- <cmd>", "Run a command in every tagged directory"},
        {"export", "Dump the database (--json | --yaml)"},
        {"import <file>", "Load a snapshot (--merge | --replace)"},
        {"setup <action>", "install / init / completion — see `doma setup --help`"},
        {"doctor", "Check the install (paths, config, DB)"},
        {"config <action>", "get / set / list — see `doma config --help`"},
        {"trash <action>", "list / restore / empty — recover from `rm`"},
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
        puts "  -y, --yes               Assume \"yes\" for confirmation prompts (env: DOMA_YES=1)"
        puts ""
        puts "Enable `doma cd <tag>` in your shell:"
        puts "  doma setup install                # auto-append to your shell's rc file"
        puts "  eval \"$(doma setup init zsh)\"     # or do it yourself"
        puts ""
        puts "The cd command lives in a shell function (a child process can't"
        puts "change its parent shell's cwd). In scripts, use --pick directly:"
        puts "  cd \"$(doma list -t <tag> --pick)\""
        puts ""
        puts "Pipelines:"
        puts "  doma list -t crystal --paths            # one path per line"
        puts "  doma list -t crystal -0 | xargs -0 ...  # NUL-safe for spaces"
        puts "  doma list -t crystal --json | jq        # structured"
        puts "  doma list -t crystal --pick             # one path (interactive if TTY)"
        puts "  doma tags --names                       # just tag names"
        puts ""
      end
    end
  end
end
