+++
title = "Navigation"
description = "Resolve a tagged directory to a single path with list --pick, then cd to it via the shell wrapper."
weight = 2
+++

The binary itself doesn't ship a `cd` subcommand — a child process can't change its parent shell's working directory. Instead, doma splits the job in two: `doma list --pick` resolves the filtered set down to a single path on stdout, and the shell wrapper installed by `doma setup install` provides `doma cd <tag>` by capturing that path and running `cd` for you.

## The primitive

```bash
doma list -t crystal --pick     # one path on stdout (interactive if TTY)
doma list --pick                # browse every registered directory
doma list -t 'work/*' --pick    # glob-filtered set
```

Resolution rules:

- **Single match** → that path is printed.
- **Multiple matches + TTY** → built-in picker opens.
- **Multiple matches + non-TTY** → most-recent match wins, with a stderr advisory.
- **Zero matches** → exit code 3, NotFound error.

When the input *looks like a path* (`/var`, `~/Downloads`, `./src`), the miss hint steers you to `doma add` instead of suggesting an unrelated tag.

## The picker

When a tag covers more than one path, `--pick` opens the built-in picker:

```
doma pick -t crystal›
▌ /Users/me/Projects/doma         #cli #crystal
  /Users/me/Projects/sandbox      #crystal
  /Users/me/Projects/cr-utils     #crystal
```

- Type to filter (case-insensitive substring match across path and tags).
- ↑/↓ to move; Enter to pick; Esc / Ctrl-C to cancel.
- The order is recency-first — the directory you used most recently floats to the top.

The picker is Crystal-native; you don't need `fzf` installed.

## Skipping the picker

```bash
doma list -t crystal --pick --first       # most-recent without prompting
doma list -t crystal --pick --builtin     # force picker even off-TTY
doma list -t crystal --pick --query auth  # pre-filter the picker
```

Without `--first`, scripts (no TTY on stdin) auto-resolve to "first match" with a stderr warning so you don't silently get a heuristic pick.

## Using it as `cd`

The shell wrapper from `doma setup install` provides the familiar form:

```bash
doma cd crystal                  # interactive picker, then cd
```

See [Shell integration](../../start/shell-integration/) for the one-line setup.

For scripts and one-offs without the wrapper, the inline form works everywhere:

```bash
cd "$(doma list -t crystal --pick)"
```

## Frecency

Every successful `--pick` updates a `last_used_at` timestamp on the chosen directory. That feeds two places:

1. The picker default order (most-recently-used first).
2. `doma list --by recent` — sort by recency rather than path.

You can see it in `doma stats` under the **Most used** section.
