require "../../utils/errors"

module Doma::CLI
  # Shared plumbing for the `setup` subcommands that take a shell name
  # (`init`, `completion`): one supported-shell list and one place for
  # the missing/unsupported error shapes, so the two can't drift.
  module ShellArg
    SUPPORTED = %w[bash zsh fish]

    # Validates the positional shell argument, raising the canonical
    # error for a missing or unknown value. Returns the shell name so
    # callers can `case` on it directly.
    def self.validate!(shell : String?) : String
      unless shell
        raise Doma::ValidationError.new("shell is required (one of: #{SUPPORTED.join(", ")})")
      end
      unless SUPPORTED.includes?(shell)
        raise Doma::ValidationError.new(
          "unsupported shell '#{shell}' (supported: #{SUPPORTED.join(", ")})"
        )
      end
      shell
    end
  end
end
