require "../../utils/errors"
require "../../utils/logger"
require "./doctor_command"
require "./init_command"
require "./install_command"

module Doma::CLI
  # Umbrella for the once-per-machine setup actions: wiring the shell
  # wrapper into rc, printing the wrapper for manual install, and
  # diagnosing the install state. Grouping them under `doma setup` keeps
  # the top-level command list focused on day-to-day operations.
  class SetupCommand
    ACTIONS = {
      "install" => "Append the shell wrapper to your rc file",
      "init"    => "Print the wrapper (for manual install)",
      "doctor"  => "Check the install (DB, config)",
    }

    def run(args : Array(String))
      if args.empty? || args.first.in?({"-h", "--help", "help"})
        print_setup_help
        return
      end

      sub = args.shift
      case sub
      when "install" then InstallCommand.new.run(args)
      when "init"    then InitCommand.new.run(args)
      when "doctor"  then DoctorCommand.new.run(args)
      else
        raise Doma::ValidationError.new(
          "unknown setup action '#{sub}' (try install, init, doctor)"
        )
      end
    end

    private def print_setup_help
      puts ""
      puts "Usage: doma setup <action> [options]"
      puts ""
      puts "Actions:"
      ACTIONS.each do |name, desc|
        puts "  #{name.ljust(8)} #{desc}"
      end
      puts ""
      puts "Run `doma setup <action> --help` for action-specific options."
      puts ""
    end
  end
end
