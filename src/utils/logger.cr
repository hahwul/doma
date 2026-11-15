require "colorize"

# `color_enabled?` (and the `color` flags derived from it) is the only
# gate. Crystal's own default also turns Colorize off whenever STDERR
# isn't a TTY, which stripped stdout color on `doma list 2>/dev/null`.
Colorize.enabled = true

module Doma
  module Logger
    extend self

    class_property? quiet : Bool = false
    class_property? debug : Bool = false
    # `NO_COLOR` (https://no-color.org/) is honored by default; the runner
    # can flip this on/off via `--no-color` / `--color`. Per the spec, an
    # empty `NO_COLOR=` doesn't count.
    class_setter no_color : Bool = !ENV["NO_COLOR"]?.presence.nil?
    # `--color`: color even when stdout isn't a TTY (e.g. `| less -R`).
    @@force_color : Bool = false

    def force_color=(value : Bool)
      @@force_color = value
    end

    # Color is keyed off STDOUT for every call, because mixing colored
    # stderr with non-tty stdout in a pipeline tends to leak escape codes
    # into grep/jq. Stderr-bound writers pass `STDERR` so a redirected
    # stderr (`2>build.log`) stays plain too — the check Crystal's own
    # default did before `Colorize.enabled = true` above.
    def color_enabled?(io : IO = STDOUT) : Bool
      # TERM=dumb mirrors Crystal's own default; `--color` still forces it.
      !@@no_color && (@@force_color || (STDOUT.tty? && io.tty? && ENV["TERM"]? != "dumb"))
    end

    def info(msg : String)
      return if @@quiet
      STDOUT.puts msg
    end

    def success(msg : String)
      return if @@quiet
      STDOUT.puts(color_enabled? ? "✓ #{msg}".colorize(:green).to_s : "✓ #{msg}")
    end

    def warn(msg : String)
      STDERR.puts(color_enabled?(STDERR) ? "! #{msg}".colorize(:yellow).to_s : "! #{msg}")
    end

    def error(msg : String)
      STDERR.puts(color_enabled?(STDERR) ? "✗ #{msg}".colorize(:red).to_s : "✗ #{msg}")
    end

    def debug(msg : String)
      return unless @@debug
      STDERR.puts(color_enabled?(STDERR) ? "· #{msg}".colorize(:dark_gray).to_s : "· #{msg}")
    end
  end
end
