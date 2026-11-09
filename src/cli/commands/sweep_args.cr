require "../../db/database"
require "../../utils/errors"
require "../../utils/suggester"
require "../../utils/tag_glob"
require "../../utils/validator"

module Doma::CLI
  # Argument checks and target selection shared by the tag sweeps
  # (`run`, `status`): tags positionally or via repeatable `-t` (AND),
  # `-x` exclusions, plus `--jobs`.
  module SweepArgs
    def self.jobs!(raw : String) : Int32
      n = raw.to_i?
      raise Doma::ValidationError.new("--jobs must be a positive integer, got '#{raw}'") if n.nil? || n < 1
      n
    end

    # At most one positional tag — a second bare word is far more often a
    # command missing its `--` than a second filter. More tags go via
    # repeatable `-t`; all of them AND together.
    def self.tags!(command : String, flag_tags : Array(String), positional : Array(String)) : Array(String)
      if positional.size > 1
        raise Doma::ValidationError.new(
          "#{command} accepts one positional tag; got #{positional.size} positional args",
          hint: "AND more tags with -t (`#{command} #{positional.first} -t #{positional[1]}`), or use a glob like 'work*'"
        )
      end
      (positional + flag_tags).uniq
    end

    # Entries carrying a match for every include and none for any exclude.
    # The first include (if any) narrows the SQL read; TagGlob then
    # applies the strict shell-glob rules to every pattern.
    def self.select(db : Doma::Database, includes : Array(String), excludes : Array(String),
                    sort : Doma::Database::SortBy) : Array(Doma::Entry)
      db.directories(includes.first?, sort: sort)
        .select { |e| Doma::TagGlob.satisfy?(e.tags, includes, excludes) }
    end

    # "'a' AND 'b', excluding 'c'" — for not-found and dry-run messages.
    def self.phrase(includes : Array(String), excludes : Array(String)) : String
      s = includes.map { |t| "'#{t}'" }.join(" AND ")
      s += ", excluding #{excluded(excludes)}" unless excludes.empty?
      s
    end

    def self.excluded(excludes : Array(String)) : String
      excludes.map { |t| "'#{t}'" }.join(", ")
    end

    # A did-you-mean for the first include that isn't a known tag. A
    # known tag in an empty AND is a legitimate result, not a typo.
    def self.typo_hint(includes : Array(String), catalog : Array(String)) : String?
      known = catalog.to_set
      includes.each do |t|
        next if known.includes?(t)
        if hint = Doma::Suggester.tag_hint_for(t, catalog)
          return hint
        end
      end
      nil
    end
  end
end
