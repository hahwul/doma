module Doma
  # Strict glob matcher for tag patterns passed to `-t` and `run <tag>`.
  #
  # SQLite's GLOB operator (which the database queries use as a permissive
  # prefilter) treats `*` as "match any chars including `/`", which means
  # `-t 'a/*'` matches `a/b/c/d/e/f`. That diverges from shell glob
  # intuition: in zsh/bash a single `*` does not cross `/`, and `**` does.
  # We re-impose those semantics in Crystal so the SQL prefilter is just
  # a coarse net and the final answer is what users expect.
  #
  # Rules:
  #   `**`  →  match anything, including `/`
  #   `*`   →  match anything *except* `/`
  #   `?`   →  match exactly one character, not `/`
  #   other →  literal match
  module TagGlob
    extend self

    # Compiled-regex memo keyed by the raw glob pattern. A single
    # `doma run 'work/*' -- …` (or `list -t 'proj/*'`) calls `match?` once
    # per tag per directory, all with the *same* pattern; without this
    # cache each call recompiles an identical regex. Patterns per process
    # are few and short-lived, so the unbounded map can't grow unboundedly
    # in practice.
    @@regex_cache = {} of String => Regex

    # True when `name` matches `pattern` under the strict semantics.
    # Plain (no glob char) patterns short-circuit to equality so the
    # common case stays cheap.
    def match?(pattern : String, name : String) : Bool
      return pattern == name unless pattern.includes?('*') || pattern.includes?('?')
      to_regex(pattern).matches?(name)
    end

    # Memoized compile — see `compile_regex` for the translation. The
    # glob → regex mapping is pure, so caching by pattern string is safe.
    private def to_regex(pattern : String) : Regex
      @@regex_cache[pattern] ||= compile_regex(pattern)
    end

    # Compile a pattern to a Crystal regex. `**` is detected before `*`
    # so we don't accidentally split it into two single-`*` tokens. The
    # output is anchored on both ends — globs are whole-string matches.
    private def compile_regex(pattern : String) : Regex
      io = IO::Memory.new
      io << "\\A"
      i = 0
      len = pattern.size
      while i < len
        ch = pattern[i]
        case ch
        when '*'
          if i + 1 < len && pattern[i + 1] == '*'
            io << ".*"
            i += 2
          else
            io << "[^/]*"
            i += 1
          end
        when '?'
          io << "[^/]"
          i += 1
        when '.', '+', '(', ')', '[', ']', '{', '}', '|', '^', '$', '\\'
          io << '\\' << ch
          i += 1
        else
          io << ch
          i += 1
        end
      end
      io << "\\z"
      Regex.new(io.to_s)
    end
  end
end
