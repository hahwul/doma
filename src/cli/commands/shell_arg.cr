require "../../utils/errors"

module Doma::CLI
  # Shared positional parsing and shell choices for `setup` actions.
  module ShellArg
    SUPPORTED = %w[bash zsh fish]

    def self.positional!(before : Array(String), after : Array(String)) : String?
      args = before + after
      if extra = args[1]?
        raise Doma::ValidationError.new("unexpected argument '#{extra}' (expected at most one shell)")
      end
      args.first?
    end

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
