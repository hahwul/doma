require "levenshtein"

module Doma
  # Picks a "did you mean ...?" candidate from a list. The threshold scales
  # with input length so short typos in long words don't dominate (e.g.
  # `cd` vs `add` shouldn't match, but `add` vs `ad` should).
  module Suggester
    extend self

    def suggest(input : String, candidates : Enumerable(String)) : String?
      return if input.empty?
      max_distance = case input.size
                     when 0..3 then 1
                     when 4..6 then 2
                     else           3
                     end

      best : String? = nil
      best_distance = max_distance + 1
      candidates.each do |c|
        d = Levenshtein.distance(input, c)
        if d < best_distance
          best_distance = d
          best = c
        end
      end
      best_distance <= max_distance ? best : nil
    end

    # Convenience wrapper that returns the rendered hint string ready to
    # attach to `Doma::Error.new(..., hint: ...)`.
    def hint_for(input : String, candidates : Enumerable(String)) : String?
      if pick = suggest(input, candidates)
        "Did you mean '#{pick}'?"
      end
    end
  end
end
