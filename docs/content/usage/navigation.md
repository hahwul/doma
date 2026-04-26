+++
title = "Navigation"
description = "Use doma cd to jump to a tagged directory, with a short_id fallback for direct addressing."
weight = 2
+++

`doma cd` resolves a directory and prints its path to stdout. With the [shell wrapper](../../start/shell-integration/) installed, your shell `cd`s to that path; without it, you can use `cd "$(doma cd <tag>)"` manually.

## Three resolution strategies

```bash
doma cd <tag>      # match a tag name (the typical case)
doma cd <id>       # match a short_id, exactly or by prefix
doma cd            # browse every registered directory
```

Resolution order: tag name first, then short_id prefix. A literal tag named `abc` always wins over a short_id that happens to start with `abc`. The short_id branch only triggers when the input is hex (`[0-9a-f]+`), so a tag-typo never silently resolves to an unrelated directory.

## Multiple matches: the picker

When a tag covers more than one path, `doma cd` opens the built-in picker:

```
doma cd crystal>
▌ /Users/me/Projects/doma         #cli #crystal
  /Users/me/Projects/sandbox      #crystal
  /Users/me/Projects/cr-utils     #crystal
```

- Type to filter (case-insensitive substring match across path and tags).
- ↑/↓ to move; Enter to pick; Esc / Ctrl-C to cancel.
- The order is recency-first — the directory you `cd`'d into most recently floats to the top.

The picker is Crystal-native; you don't need `fzf` installed. (Earlier doma versions shelled out to `fzf` — that dependency was dropped.)

## Skipping the picker

```bash
doma cd crystal --first         # most-recent without prompting
doma cd crystal --index 2       # the N-th match (1-based)
doma cd 0dc0db9                 # exact short_id, no picker needed
```

Inside scripts (where stdin isn't a TTY), `doma cd` automatically falls back to `--first` semantics so the command never blocks waiting for input.

## Browsing without a tag

```bash
doma cd
```

Lists every registered directory. Useful when you remember the project name but not the tag. Add `--query` to pre-filter:

```bash
doma cd --query auth
```

## Frecency

Every successful `cd` updates a `last_used_at` timestamp on the chosen directory. That feeds two places:

1. The picker default order (most-recently-used first).
2. `doma list --by recent` — sort by recency rather than path.

You can see it in `doma stats` under the **Most used** section.
