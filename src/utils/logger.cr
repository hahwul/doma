require "colorize"

module Doma
  module Logger
    extend self

    @@quiet : Bool = false
    @@debug : Bool = false
    # `NO_COLOR` (https://no-color.org/) is honored by default; the runner
    # can flip this on/off via `--no-color` / `--color`.
    @@no_color : Bool = ENV["NO_COLOR"]? != nil

    def quiet=(value : Bool)
      @@quiet = value
    end

    def quiet? : Bool
      @@quiet
    end

    def debug=(value : Bool)
      @@debug = value
    end

    def debug? : Bool
      @@debug
    end

    def no_color=(value : Bool)
      @@no_color = value
    end

    # Color is keyed off STDOUT specifically, even for stderr-bound calls,
    # because mixing colored stderr with non-tty stdout in a pipeline tends
    # to leak escape codes into grep/jq more often than the reverse.
    def color_enabled? : Bool
      !@@no_color && STDOUT.tty?
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
