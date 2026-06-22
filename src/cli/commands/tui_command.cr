require "option_parser"
require "../../db/database"
require "../../tui/app"
require "../../utils/errors"
require "../../utils/logger"

module Doma::CLI
  # `doma tui` — the interactive fuzzy finder. Also the default action when
  # `doma` is run with no subcommand (the runner dispatches here when stdin is
  # a TTY).
  #
  # Output contract (identical to `doma list --pick`): the UI lives entirely on
  # /dev/tty, and on selection the chosen path is printed to STDOUT after the
  # screen is torn down — so a shell wrapper can `cd "$(doma)"`. Cancellation
  # prints nothing and exits 130 so the wrapper's `cd` is skipped.
  class TuiCommand
    def run(args : Array(String))
      query : String? = nil
      tag : String? = nil

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma tui [--query Q] [-t TAG]"
        p.on("--query Q", "Pre-fill the search box") { |q| query = q }
        p.on("-t TAG", "--tag TAG", "Pre-seed a tag: filter") { |t| tag = t }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args { |_, _| }
      end
      parser.parse(args)

      unless STDIN.tty?
        raise Doma::ValidationError.new(
          "doma tui requires an interactive terminal",
          hint: "use `doma list` for non-interactive output"
        )
      end

      selected = false
      db = Doma::Database.open
      begin
        entries = db.directories(sort: Doma::Database::SortBy::Recent)
        if entries.empty?
          Doma::Logger.warn "no directories registered yet"
          STDERR.puts "  try `doma add .` to register the current directory"
          return
        end

        result = run_app(db, entries, initial_query(query, tag))
        if result.selected? && (path = result.path)
          bump_used_safe(db, path)
          puts path
          selected = true
        end
      ensure
        db.close
      end

      # Cancellation (Esc/Ctrl-C) → no path on stdout, non-zero exit so the
      # shell wrapper's `cd` is skipped. Matches `list --pick`.
      exit 130 unless selected
    end

    private def run_app(db : Doma::Database, entries : Array(Doma::Entry), query : String) : Doma::TUI::App::Result
      Doma::TUI::App.new(db, entries, query).run
    rescue IO::Error
      # No controlling terminal even though stdin looked like a TTY.
      raise Doma::Error.new(
        "no controlling terminal for the TUI",
        hint: "use `doma list` for non-interactive output"
      )
    end

    private def initial_query(query : String?, tag : String?) : String
      parts = [] of String
      parts << "tag:#{tag}" if tag && !tag.empty?
      parts << query if query && !query.empty?
      parts.join(" ")
    end

    # Frecency is best-effort: a failure here must never block the selection
    # from reaching stdout. Mirrors `list --pick`'s bump_used_safe.
    private def bump_used_safe(db : Doma::Database, path : String)
      db.bump_used!(path)
    rescue
    end
  end
end
