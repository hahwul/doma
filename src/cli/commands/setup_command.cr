require "../../utils/errors"
require "../../utils/logger"
require "./completion_command"
require "./init_command"
require "./install_command"

module Doma::CLI
  # Umbrella for the once-per-machine setup actions: wiring the shell
  # wrapper into rc, printing the wrapper for manual install, and shell
  # completion. (Install diagnostics live at the top level as
  # `doma doctor` — they aren't shell-integration-specific.)
  class SetupCommand
    ACTIONS = {
      "install"    => "Append the shell wrapper to your rc file",
      "init"       => "Print the wrapper (for manual install)",
      "completion" => "Print a shell completion script (bash|zsh|fish)",
    }

    def run(args : Array(String))
      if args.empty? || args.first.in?({"-h", "--help", "help"})
        print_setup_help
        return
      end

      sub = args.shift
      case sub
      when "install"    then InstallCommand.new.run(args)
      when "init"       then InitCommand.new.run(args)
      when "completion" then CompletionCommand.new.run(args)
      when "doctor"
        # Doctor moved to the top level (`doma doctor`). Keep a clear
        # redirect for users with the old habit rather than silently
        # erroring or, worse, double-dispatching.
        Doma::Logger.error "`doma setup doctor` moved to `doma doctor`"
        STDERR.puts "  Run `doma doctor` instead."
        exit 1
      else
        raise Doma::ValidationError.new(
          "unknown setup action '#{sub}' (try install, init, completion)"
        )
      end
    end

    private def print_setup_help
      puts ""
      puts "Usage: doma setup <action> [options]"
      puts ""
      puts "Actions:"
      ACTIONS.each do |name, desc|
        puts "  #{name.ljust(11)} #{desc}"
      end
      puts ""
      puts "Run `doma setup <action> --help` for action-specific options."
      puts ""
    end
  end
end
