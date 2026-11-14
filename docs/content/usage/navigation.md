+++
title = "Navigation"
description = "Resolve a tagged directory to a single path with list --pick, then cd to it via the shell wrapper."
weight = 2
+++

`doma list --pick` resolves a filtered set down to a single path on stdout. The shell wrapper installed by [`doma setup install`](../../start/shell-integration/) builds `doma cd <tag>` on top of it.

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

When the input *looks like a path* (`/var`, `~/Downloads`, `./src`), the miss hint steers you to `doma add` instead of an unrelated tag.

## The picker

The picker is the same finder as `doma tui`, opened over just the matching directories:

```
▌ /Users/me/Projects/doma         #cli #crystal
  /Users/me/Projects/sandbox      #crystal
  /Users/me/Projects/cr-utils     #crystal
3/3   ↑↓ move · enter pick · ^y copy · ? help · esc quit
›
```

- Type to fuzzy-filter; the `tag:` / `-tag:` / `id:` / `path:` operators work here too (`?` for help).
- ↑/↓ to move; Enter to pick; Esc / Ctrl-C to cancel.
- Order is recency-first (or `--by`) until you type.

## Skipping the picker

```bash
doma list -t crystal --pick --first       # most-recent without prompting
doma list -t crystal --pick --builtin     # force picker even off-TTY
doma list -t crystal --pick --query auth  # pre-filter the picker
```

## Frecency

Every successful `--pick` updates `last_used_at` on the chosen directory. That feeds:

1. The picker's default order (most-recent first).
2. `doma list --by recent`.
3. The **Most used** section in `doma stats`.
