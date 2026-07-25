require "./errors"

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

    # Comfortably above any real tag glob (`work/**`, `proj-*`, …) but far
    # below the point where a translated pattern's chain of `.*`/`[^/]*`
    # tokens makes PCRE2's JIT compiler choke — verified empirically
    # around ~4500 chained star-tokens (tens of thousands of compiled
    # chars). Past that, `Regex.new` doesn't raise a catchable timeout —
    # it raises a raw `ArgumentError` ("Regex JIT compile error: -68")
    # that only the CLI's generic top-level handler catches, surfacing
    # as an opaque "internal error" instead of a clean rejection. Reject
    # early with a real validation error instead.
    MAX_PATTERN_LEN = 256

    # True when `s` carries a glob metacharacter (`*` or `?`) and so needs
    # GLOB matching rather than plain equality. Centralizes the check that
    # list/run/status and the SQL prefilter each spelled out inline.
    def pattern?(s : String) : Bool
      s.includes?('*') || s.includes?('?')
    end

    # True when `name` matches `pattern` under the strict semantics.
    # Plain (no glob char) patterns short-circuit to equality so the
    # common case stays cheap.
    def match?(pattern : String, name : String) : Bool
      return pattern == name unless pattern?(pattern)
      to_regex(pattern).matches?(name)
    end

    # Narrow `entries` to those carrying a tag that matches `pattern` under
    # the strict semantics. A no-op for a plain (non-glob) pattern — the SQL
    # layer already returned the exact-match set, so there's nothing to
    # re-filter. The block yields each entry's tag list, keeping this
    # decoupled from any particular row type (list/run/status all pass
    # `&.tags`).
    def filter(entries : Array(T), pattern : String, & : T -> Array(String)) : Array(T) forall T
      return entries unless pattern?(pattern)
      entries.select { |e| (yield e).any? { |t| match?(pattern, t) } }
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
      if pattern.size > MAX_PATTERN_LEN
        raise Doma::ValidationError.new(
          "tag pattern is too long (#{pattern.size} chars, max #{MAX_PATTERN_LEN})"
        )
      end
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
