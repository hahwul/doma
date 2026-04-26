require "../utils/config"
require "./picker"

module Doma
  # Picks one string from a list. Three strategies:
  #
  #   - Auto    : interactive picker if STDIN is a TTY, else first
  #   - Builtin : always use the picker (forces interactive)
  #   - First   : always pick the first match (deterministic, scriptable)
  #
  # The interactive form is implemented in Doma::Picker — pure Crystal,
  # no external `fzf` binary required.
  module Selector
    extend self

    record Result, value : String, cancelled : Bool do
      def self.cancelled
        new("", true)
      end
    end

    def pick(choices : Array(String), prompt : String = "Select", *, mode : Settings::SelectorMode? = nil) : Result
      raise ArgumentError.new("choices must not be empty") if choices.empty?
      return Result.new(choices.first, false) if choices.size == 1

      effective = mode || Settings.current.selector
      effective = resolve_auto if effective == Settings::SelectorMode::Auto

      case effective
      in Settings::SelectorMode::First
        Result.new(choices.first, false)
      in Settings::SelectorMode::Builtin
        run_builtin(choices, prompt)
      in Settings::SelectorMode::Auto
        # already resolved above; this branch satisfies exhaustiveness.
        Result.new(choices.first, false)
      end
    end

    private def resolve_auto : Settings::SelectorMode
      STDIN.tty? ? Settings::SelectorMode::Builtin : Settings::SelectorMode::First
    end

    private def run_builtin(choices : Array(String), prompt : String) : Result
      items = choices.map { |c| Picker::Item.new(value: c, label: c) }
      result = Picker.pick(items, prompt)
      if result.cancelled
        Result.cancelled
      else
        Result.new(result.value || choices.first, false)
      end
    end
  end
end
