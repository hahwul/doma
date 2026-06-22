module Doma
  module TUI
    # Pure fuzzy subsequence matcher. Returns a score *and* the matched
    # codepoint indices so callers can both rank results and highlight the
    # matched characters. No terminal or database dependencies — it's
    # exercised in isolation by `spec/tui_fuzzy_spec.cr`.
    #
    # doma deliberately ships no fuzzy matcher elsewhere (the `Picker` filter
    # is substring-only by design); this one exists only for the interactive
    # TUI, where ranking and highlight matter.
    #
    # The algorithm is a single greedy left-to-right pass: each query
    # character is matched to the next equal target character. That's O(n)
    # and good enough for doma's corpus (a few hundred-to-thousand paths); it
    # can pick a slightly worse position than an optimal DP would, which is an
    # acceptable trade for the simplicity.
    module Fuzzy
      extend self

      # A successful match: a relevance `score` (higher is better) and the
      # codepoint indices into the *target* that were matched.
      record Match, score : Int32, positions : Array(Int32)

      # Scoring weights, tuned for filesystem paths: contiguous runs and hits
      # right after a separator carry the most signal; deep, scattered
      # matches the least.
      MATCH       = 16 # each matched character
      CONSECUTIVE =  8 # match immediately follows the previous match
      BOUNDARY    = 12 # match sits at a word boundary (start or after a sep)
      START       =  8 # the first match is at index 0
      CAMEL       =  8 # camelCase hump (Upper preceded by lower)
      BASENAME    = 24 # every match lands inside the basename segment
      GAP_PENALTY =  1 # per skipped character between two matches
      GAP_CAP     = 32 # ceiling on the total internal-gap penalty
      LEAD_GAP    =  2 # flat penalty for a match that doesn't start at 0

      # Characters that, when they precede a match, make it a "word boundary".
      BOUNDARY_BEFORE = {'/', '-', '_', '.', ' '}

      # Returns nil when `query` is not a (case-insensitive) subsequence of
      # `target`. An empty query trivially matches with score 0 and no
      # highlight positions, so an empty search box keeps every row.
      #
      # `basename_bonus` rewards matches confined to the final path segment;
      # the `path:` query operator disables it to weigh all segments equally.
      def score(query : String, target : String, *, basename_bonus : Bool = true) : Match?
        return Match.new(0, [] of Int32) if query.empty?

        q = query.downcase.chars
        original = target.chars
        lowered = target.downcase.chars

        positions = [] of Int32
        total = 0
        qi = 0
        ti = 0
        last_match = -1
        gap_total = 0

        while qi < q.size
          # Advance to the next target char equal to the current query char.
          while ti < lowered.size && lowered[ti] != q[qi]
            ti += 1
          end
          return if ti >= lowered.size

          total += MATCH
          total += BOUNDARY if ti == 0 || BOUNDARY_BEFORE.includes?(lowered[ti - 1])
          total += START if positions.empty? && ti == 0
          total += CAMEL if ti > 0 && original[ti].uppercase? && original[ti - 1].lowercase?

          if last_match >= 0
            gap = ti - last_match - 1
            if gap == 0
              total += CONSECUTIVE
            else
              gap_total += gap
            end
          elsif ti > 0
            total -= LEAD_GAP
          end

          positions << ti
          last_match = ti
          qi += 1
          ti += 1
        end

        total -= Math.min(gap_total * GAP_PENALTY, GAP_CAP)

        if basename_bonus
          start = basename_start(target)
          total += BASENAME if positions.all? { |p| p >= start }
        end

        Match.new(total, positions)
      end

      # Codepoint index of the first character of the basename — one past the
      # last `/`, or 0 when the target has no separator.
      private def basename_start(target : String) : Int32
        idx = target.rindex('/')
        idx ? idx + 1 : 0
      end
    end
  end
end
