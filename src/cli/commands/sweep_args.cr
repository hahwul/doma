require "../../db/database"
require "../../services/git_status"
require "../../services/last_run"
require "../../utils/parallel"
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

    # Dynamic sets: computed per call rather than stored as tags. Real tags
    # must start alphanumeric, so the `@` namespace can't collide.
    SETS = {
      "@failed"     => "directories that failed the last `doma run`",
      "@dirty"      => "git repos with uncommitted changes",
      "@ahead"      => "git repos ahead of their upstream",
      "@behind"     => "git repos behind their upstream as of the last fetch",
      "@unreleased" => "git repos with commits since their latest tag",
    }

    # The sets one `git status` probe answers. Public so `status` can filter
    # on the probe it runs anyway instead of probing twice.
    # ponytail: outside `status` each set probes on its own, so
    # `-t @dirty -t @ahead` runs git twice on the survivors — memoize per
    # path if that bites.
    STATUS_SETS = {
      "@dirty"  => ->(s : Doma::GitStatus::Status) { s.dirty > 0 },
      "@ahead"  => ->(s : Doma::GitStatus::Status) { s.ahead > 0 },
      "@behind" => ->(s : Doma::GitStatus::Status) { s.behind > 0 },
    }

    # Entries carrying a match for every include and none for any exclude.
    # The first tag include (if any) narrows the SQL read; TagGlob then
    # applies the strict shell-glob rules to every pattern, and `@sets`
    # narrow what's left.
    def self.select(db : Doma::Database, includes : Array(String), excludes : Array(String),
                    sort : Doma::Database::SortBy, jobs : Int32? = nil) : Array(Doma::Entry)
      includes, set_in = split_sets(includes)
      excludes, set_ex = split_sets(excludes)
      entries = db.directories(includes.first?, sort: sort)
        .select { |e| Doma::TagGlob.satisfy?(e.tags, includes, excludes) }
      apply_sets(entries, set_in, set_ex, jobs)
    end

    # Splits `@set` names out of a selector list → {tags, sets}. Unknown
    # sets are an error, not a silent empty match.
    def self.split_sets(names : Array(String)) : {Array(String), Array(String)}
      sets, tags = names.partition(&.starts_with?('@'))
      sets.each do |s|
        next if SETS.has_key?(s)
        raise Doma::ValidationError.new("unknown set '#{s}'",
          hint: "known sets: #{SETS.map { |k, v| "#{k} (#{v})" }.join(", ")}")
      end
      {tags, sets}
    end

    # Applied after tag filtering, and with the cheap `@failed` file read
    # before the git sets, so git only probes what's left.
    def self.apply_sets(entries : Array(Doma::Entry), includes : Array(String), excludes : Array(String),
                        jobs : Int32? = nil) : Array(Doma::Entry)
      includes.sort_by { |s| s == "@failed" ? 0 : 1 }.each do |s|
        members = members(s, entries, jobs)
        entries = entries.select { |e| members.includes?(e.path) }
      end
      excludes.sort_by { |s| s == "@failed" ? 0 : 1 }.each do |s|
        members = members(s, entries, jobs)
        entries = entries.reject { |e| members.includes?(e.path) }
      end
      entries
    end

    private def self.members(set : String, entries : Array(Doma::Entry), jobs : Int32?) : Set(String)
      return Doma::LastRun.failed.to_set if set == "@failed"
      # Without git every probe reads "not a member", and `-x @dirty` would
      # quietly exclude nothing — refuse instead.
      unless Doma::GitStatus.available?
        raise Doma::Error.new("git executable not found on PATH",
          hint: "#{set} shells out to git; install it or put it on your PATH")
      end
      # One git call per candidate, overlapped like `status`. The probes
      # never raise; a missing dir or non-repo is simply not a member.
      by_status = STATUS_SETS[set]?
      hits = Doma::Parallel.map(entries, jobs || Doma::Parallel.default_jobs) do |e|
        member = by_status ? by_status.call(Doma::GitStatus.probe(e.path)) : (Doma::GitStatus.commits_since_tag(e.path) || 0) > 0
        e.path if member
      end
      hits.compact.to_set
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

    # Why an include came back empty: a did-you-mean for the first tag
    # that doesn't exist, or a note that `@failed` has nothing in it. A
    # known tag in an empty AND is a legitimate result, not a typo.
    def self.miss_hint(includes : Array(String), catalog : Array(String)) : String?
      known = catalog.to_set
      includes.each do |t|
        next if known.includes?(t) || t.starts_with?('@')
        if hint = Doma::Suggester.tag_hint_for(t, catalog)
          return hint
        end
      end
      if includes.includes?("@failed") && Doma::LastRun.failed.empty?
        "@failed is empty: the last `doma run` had no failures"
      end
    end
  end
end
