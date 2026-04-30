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
  end
end
