require "option_parser"
require "../../services/installer"
require "../../utils/errors"
require "../../utils/logger"

module Doma::CLI
  # One-shot setup for the shell wrapper that makes `doma cd` actually
  # change directory. Most users won't bother doing this manually — the
  # wrapper-line-in-rc-file pattern is well known but easy to forget —
  # so this command does it for them, idempotently.
  class InstallCommand
    def run(args : Array(String))
      shell : String? = nil
      assume_yes = false
      dry_run = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma install [<shell>] [--yes] [--dry-run]"
        p.on("-y", "--yes", "Skip the confirmation prompt") { assume_yes = true }
        p.on("-n", "--dry-run", "Show what would change without writing") { dry_run = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args do |before, after|
          shell ||= before.first? || after.first?
        end
      end
      parser.parse(args)

      effective = shell || Doma::Installer.detect_shell
      raise Doma::ValidationError.new(
        "couldn't detect shell from $SHELL — pass it explicitly: `doma install zsh`"
      ) unless effective

      plan = Doma::Installer.plan(effective)

      if plan.already_installed
        Doma::Logger.info "doma is already wired into #{plan.rc_path}"
        Doma::Logger.info "nothing to do — restart your shell if `doma cd` still doesn't change dir"
        return
      end

      if dry_run
        STDOUT.puts "Would append to #{plan.rc_path}:"
        STDOUT.puts ""
        STDOUT.puts plan.block
        return
      end

      unless assume_yes
        unless confirm(plan)
          Doma::Logger.warn "aborted"
          exit 1
        end
      end

      Doma::Installer.install!(plan)
      Doma::Logger.success "installed to #{plan.rc_path}"
      Doma::Logger.info "restart your shell, or run: source #{plan.rc_path}"
    end

    private def confirm(plan : Doma::Installer::Plan) : Bool
      # Non-interactive without --yes is intentionally a hard "no" — same
      # rule as `doma import --replace`. Modifying the user's rc file is
      # invasive enough that an unattended pipe shouldn't auto-accept.
      unless STDIN.tty?
        Doma::Logger.error "running non-interactively requires --yes (or --dry-run to preview)"
        return false
      end

      STDERR.puts "Append doma shell integration to #{plan.rc_path}? [Y/n] "
      STDERR.flush
      raw = STDIN.gets
      return true if raw.nil?
      response = raw.strip.downcase
      response.empty? || response.in?({"y", "yes"})
    end
  end
end
