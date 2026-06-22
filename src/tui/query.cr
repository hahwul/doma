require "../models/entry"
require "../utils/tag_glob"
require "./fuzzy"

module Doma
  module TUI
    # Parses the search box into a structured query, then filters and ranks
    # the in-memory entry set. Both halves are pure (no terminal, no DB) so
    # they're unit-testable — see `spec/tui_query_spec.cr`.
    #
    # Grammar (whitespace-separated tokens):
    #   tag:PATTERN    entry must have a tag matching PATTERN (glob via
    #                  TagGlob); repeatable → AND
    #   -tag:PATTERN   entry must NOT have any tag matching PATTERN
    #   !tag:PATTERN   alias for -tag:
    #   id:PREFIX      entry.short_id must start with PREFIX (case-insensitive)
    #   path:TERM      fuzzy term over the full path, no basename weighting
    #   TERM           bare fuzzy term over the path (basename-weighted)
    #
    # Tag / id tokens are gates (they don't contribute to the score); each
    # fuzzy term must match (AND) and their scores sum.
    module Query
      extend self

      record Term, text : String, path_only : Bool
      record Parsed,
        tag_includes : Array(String),
        tag_excludes : Array(String),
        id_prefixes : Array(String),
        terms : Array(Term) do
        def empty? : Bool
          tag_includes.empty? && tag_excludes.empty? && id_prefixes.empty? && terms.empty?
        end
      end

      record Scored, entry : Entry, score : Int32, positions : Array(Int32)

      def parse(raw : String) : Parsed
        tag_includes = [] of String
        tag_excludes = [] of String
        id_prefixes = [] of String
        terms = [] of Term

        raw.split.each do |tok|
          if v = strip_prefix(tok, "tag:")
            tag_includes << v unless v.empty?
          elsif v = strip_prefix(tok, "-tag:")
            tag_excludes << v unless v.empty?
          elsif v = strip_prefix(tok, "!tag:")
            tag_excludes << v unless v.empty?
          elsif v = strip_prefix(tok, "id:")
            id_prefixes << v.downcase unless v.empty?
          elsif v = strip_prefix(tok, "path:")
            terms << Term.new(v, path_only: true) unless v.empty?
          else
            terms << Term.new(tok, path_only: false)
          end
        end

        Parsed.new(tag_includes, tag_excludes, id_prefixes, terms)
      end

      # Filters `entries` by the parsed gates and fuzzy terms, returning the
      # survivors sorted by score (desc) with a *stable* tiebreak on the input
      # order — so an empty query preserves the caller's ordering (recency).
      def filter(entries : Array(Entry), parsed : Parsed) : Array(Scored)
        scored = [] of Scored

        entries.each do |entry|
          next unless tags_satisfy?(entry, parsed)
          next unless id_satisfy?(entry, parsed)

          total = 0
          positions = [] of Int32
          ok = true
          parsed.terms.each do |term|
            match = Fuzzy.score(term.text, entry.path, basename_bonus: !term.path_only)
            unless match
              ok = false
              break
            end
            total += match.score
            positions.concat(match.positions)
          end
          next unless ok

          scored << Scored.new(entry, total, positions.uniq!.sort!)
        end

        # Crystal's sort_by is not guaranteed stable; carry the original index
        # so equal scores keep their incoming (recency) order.
        scored.map_with_index { |s, i| {s, i} }
          .sort_by! { |pair| {-pair[0].score, pair[1]} }
          .map(&.[0])
      end

      private def strip_prefix(token : String, prefix : String) : String?
        token.starts_with?(prefix) ? token[prefix.size..] : nil
      end

      private def tags_satisfy?(entry : Entry, parsed : Parsed) : Bool
        parsed.tag_includes.each do |pattern|
          return false unless entry.tags.any? { |tag| TagGlob.match?(pattern, tag) }
        end
        parsed.tag_excludes.each do |pattern|
          return false if entry.tags.any? { |tag| TagGlob.match?(pattern, tag) }
        end
        true
      end

      private def id_satisfy?(entry : Entry, parsed : Parsed) : Bool
        parsed.id_prefixes.all? { |prefix| entry.short_id.downcase.starts_with?(prefix) }
      end
    end
  end
end
