---
name: doma
description: Use doma both to (1) discover directory paths the user has already tagged so you can operate on them in bulk, and (2) register or bookmark new directories when the user's intent calls for persistence ("track this", "bookmark this", "I'll come back later"). Trigger when the user references "my X projects" / "all directories tagged Y" / "every repo I marked as Z", asks for a category-spanning chore ("update CI for all my Crystal projects"), or asks to save/track/remember a path. Skip when the user names explicit paths for one-shot work, or when `which doma` shows it isn't installed.
---

# doma: Find, Tag, or Bookmark Directories

doma is a directory tag manager. The user attaches tags to directories
(`crystal`, `work/proj-a`, `bookmark`, etc.) and persists them in a
SQLite database under `~/.config/doma/`. As an agent you have two
jobs: query that database to drive other operations, **and** add to it
when the user's intent calls for it.

## When the user wants to discover paths

The request mentions a category of directories rather than specific
ones. Check doma before guessing:

```bash
doma tags --names              # what tags exist on this machine?
doma list -t crystal --paths   # paths under that tag, one per line
```

If `doma tags --names` doesn't list a tag matching the user's category,
fall back to whatever discovery method you'd use otherwise (filesystem
search, asking the user). Don't guess at a tag name that wasn't
returned — `doma list -t guess` returns nothing for a non-existent
tag, and silent emptiness is worse than asking.

### Read modes

| Want | Command | Why |
|---|---|---|
| One path per line, for `while read` / `xargs` | `doma list -t TAG --paths` | The default newline-separated form |
| NUL-separated, paths with spaces | `doma list -t TAG -0` | Pipe to `xargs -0`. Safer than `--paths` when paths might contain spaces |
| Structured (id, short_id, basename, tags) | `doma list -t TAG --json` | When you need more than just the path — e.g. preserving short_id for later reference |
| Substring across path/basename/tag | `doma list <query>` | Single substring match. Combines with `-t` for intersection. Multiple positional args are joined by a space — they are *not* AND-ed |
| Sorted by recency | `doma list --by recent` | Most-recently-used first; useful when "the project I was just working on" is in scope |
| Just the tag names | `doma tags --names` | Cheap probe before committing to a tag |

## When the user wants to register or bookmark paths

Write operations are real state changes; do them when the user's
intent clearly maps to "remember this", not as a side effect of
unrelated work.

| User says... | Command | Notes |
|---|---|---|
| "Track this project" / "I'll be working on it" | `doma add <path> -t <category>` | Permanent (no TTL) |
| "Track all of these as `<name>`" | `doma add <path1> <path2> ... -t <name>` | Multi-path is one command |
| "Bookmark this for review" / "Remember this for later" | `doma mark <bookmark-name>` | cwd + 7-day TTL — equivalent to `add . -t NAME --tmp`, just shorter |
| "Mark these for the auth review session" | `cd <each>` then `doma mark auth-review` | Loop the marks; tags accumulate |
| "Save this for the next week" | `doma add . -t reading --tmp` | Or `doma mark reading` |
| "Save this for two days" | `doma add . -t reading --ttl 2d` | Custom duration; `mark` only covers the 7d default |
| "Untag this" | `doma rm <path> -t <tag>` | Removes the tag; the path entry stays if it has other tags |
| "Forget this directory entirely" | `doma rm <path>` | Drops every tag and the path row |

`mark` is the right tool for transient session-style organization
(code review, refactor sweep, debugging deep-dive). `add` is for
durable categorization that survives multiple sessions.

### Multi-tag and multi-path forms

```bash
doma add /path        -t crystal -t cli           # multiple tags, one path
doma add /a /b /c     -t shared                   # one tag, many paths
doma add . -t crystal --auto-tag --git-tag        # +basename, +github/repo derived
doma mark spike skim review                       # multiple temp tags on cwd at once
```

## Operating on read results

Two patterns. Pick based on whether the operation needs to step inside
each directory or just needs the path string.

**Pattern A — iterate paths in your own loop (most common):**

```bash
doma list -t crystal --paths | while read -r dir; do
  # use $dir however — Read tool, Edit, Bash with cwd=$dir, etc.
done
```

For paths-with-spaces safety, prefer NUL-separated:

```bash
doma list -t crystal -0 | xargs -0 -I{} sh -c 'cd "{}" && grep -l TODO **/*.cr'
```

**Pattern B — let doma run a command per directory:**

```bash
doma run crystal -- shards build      # sequential, stops on Ctrl-C
doma run crystal --parallel -- ...    # concurrent, output interleaves
doma run crystal --fail-fast -- ...   # halt on first non-zero exit
```

Use `doma run` only when the operation is uniform enough to express as
a single shell command. For per-directory logic that involves reading
files or making decisions, Pattern A keeps the work in your hands.

## Pitfalls

- **`doma cd` is a shell function, not a binary subcommand.** Calling
  the bare binary with `cd` prints an error pointing at
  `doma setup install`. The agent-friendly equivalent is
  `path=$(doma list -t <tag> --pick)` — it prints exactly one path
  (most-recent under non-TTY, with a stderr advisory when the tag is
  ambiguous). When you need every path, use `doma list -t TAG --paths`.

- **Symlinks are resolved.** doma stores the canonical real path, so a
  registered `/var/foo` will surface as `/private/var/foo` on macOS.
  Don't be alarmed if the listed paths look "different" from what the
  user might type.

- **Expired tags are hidden by default.** When the user uses TTL tags
  (`--ttl 7d`, `--tmp`, `mark`), an expired row vanishes from
  `list -t TAG` but the directory itself remains under any non-expired
  tags. Add `--include-expired` if the user explicitly asked to audit.

- **Empty result is a real outcome, not an error.** `doma list -t X`
  with no matches exits 0 with a one-line stderr. Check for empty
  stdout before iterating; don't proceed assuming you have paths.

- **Re-tagging refreshes / clears the TTL.** `doma add . -t reading
  --tmp` resets the timer; the same call without `--tmp` reverts the
  tag to permanent. Be aware if you're scripting both operations on
  the same path.

- **Bulk destructive ops need explicit user intent.** `prune --gone`,
  `prune --expired`, and `import --replace` are sweeping operations.
  Don't reach for them as housekeeping unless the user asked. The
  per-path forms (`rm <path>`, `rm <path> -t TAG`) are fine when the
  user pointed at something specific.

- **`add`/`mark` are state changes — match them to intent.** Saying "look
  at this directory" is not the same as "track this directory."
  Persist only when the user's wording clearly implies "remember this
  for later" or "I want to come back here." When in doubt, ask.

## Common request shapes

| User says... | First doma call |
|---|---|
| "Update Crystal version in CI for all my Crystal projects" | `doma list -t crystal --paths` |
| "Check git status across my work repos" | `doma list -t 'work/*' --paths` (glob applies to `list -t` and `run`) |
| "Find that bookmarked thing about auth" | `doma list -t bookmark auth` (tag filter ∩ substring `auth`) |
| "What was I working on last?" | `doma list --by recent` (top entries are most-recent cd targets) |
| "Is this directory registered? with what tags?" | `doma info` (cwd) or `doma info <path>` — single-entry detail, exits 3 if not registered |
| "Run specs across all the Crystal projects in parallel" | `doma run crystal --parallel -- crystal spec` |
| "I'll be working on this project for a while" | `doma add . -t <category>` |
| "Bookmark this so I come back later" | `doma mark <name>` |
| "Mark these dirs for the auth review" | loop: cd into each, `doma mark auth-review` |
| "Forget the bookmark" | `doma rm <path> -t bookmark` (or wait for the TTL) |
| "Show me what's expiring soon" | `doma list --include-expired` (then filter by `expires_at` in `--json`) |

## Stable identifiers

Every directory has a 7-char `short_id` (visible in `list` output and
in `--json`). It survives re-tagging and renames, so when you need to
refer to a specific entry across multiple steps, store the short_id —
not the path (which can be moved) and not the index (which changes
when the list reorders).

```bash
ID=$(doma list -t crystal --json | jq -r '.[] | select(.basename=="doma") | .short_id')
# ... later, after the user moved the directory ...
PATH_NOW=$(doma list --json | jq -r --arg id "$ID" '.[] | select(.short_id==$id) | .path')
```

short_ids are accepted by `rm <id>` and `trash restore <id>`. They are
*not* accepted by `list --pick` (use the tag), and the bare binary's
`cd` subcommand has been removed in favor of the shell-wrapper +
`list --pick` split.

## When NOT to invoke

- The user named explicit paths (`/Users/me/projects/foo`, `./bar`)
  for one-shot work. Just operate on those — doma adds nothing.
- `which doma` returns nothing, or `doma --version` errors. Fall back
  to filesystem discovery (`fd`, `find`) and tell the user doma isn't
  available.
- The operation only touches the current directory and the user
  didn't ask to track it. doma is for cross-directory work and for
  persisting intent — one-shot tasks don't need it.
