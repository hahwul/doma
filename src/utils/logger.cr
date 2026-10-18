require "colorize"

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
      # Colorize strips escapes on its own when not on a TTY.
      Colorize.enabled = true if value
    end

    # Color is keyed off STDOUT specifically, even for stderr-bound calls,
    # because mixing colored stderr with non-tty stdout in a pipeline tends
    # to leak escape codes into grep/jq more often than the reverse.
    def color_enabled? : Bool
      !@@no_color && (@@force_color || STDOUT.tty?)
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
      STDERR.puts(color_enabled? ? "! #{msg}".colorize(:yellow).to_s : "! #{msg}")
    end

    def error(msg : String)
      STDERR.puts(color_enabled? ? "✗ #{msg}".colorize(:red).to_s : "✗ #{msg}")
    end

    def debug(msg : String)
      return unless @@debug
      STDERR.puts(color_enabled? ? "· #{msg}".colorize(:dark_gray).to_s : "· #{msg}")
    end
  end
end
