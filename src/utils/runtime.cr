module Doma
  # Process-wide runtime flags driven by global CLI args (and a few env
  # vars). Lives outside Logger because confirmation policy isn't
  # output-shape state.
  module Runtime
    extend self

    @@assume_yes : Bool = ENV["DOMA_YES"]? == "1"

    def assume_yes=(value : Bool)
      @@assume_yes = value
    end

    def assume_yes? : Bool
      @@assume_yes
    end

    # True when nobody has actually consented to a destructive action:
    # no -y/--yes, no DOMA_YES=1, and there's no human at a TTY to ask
    # either. A caller that's about to do something irreversible (e.g.
    # `rm --hard`, `prune --gone --hard`) should refuse rather than
    # proceed — an unattended invocation (cron, a pipe, a wrapper
    # script) has no way to signal consent other than the flag.
    def non_interactive_without_consent? : Bool
      !assume_yes? && !(STDIN.tty? && STDOUT.tty?)
    end
  end
end
