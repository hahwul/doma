+++
title = "Concepts"
description = "How doma thinks: paths as the unit, tags as labels, frecency, soft-delete."
weight = 4
+++

A short mental model so the rest of the docs land cleanly.

## The unit is the path

doma's primary record is a **directory** — a canonical absolute path on disk. Every other thing (tags, TTLs, last-used timestamps) hangs off that path. Tags are labels, not buckets: removing a tag doesn't remove the directory; removing a directory removes all its tags.

```
path: /Users/me/Projects/doma
  ├─ tags: crystal, cli
  ├─ short_id: 0dc0db9          ← stable handle that survives renames
  ├─ created_at, last_used_at
  └─ exists?: true
```

Paths are canonicalized — `~`, symlinks, and trailing slashes all collapse to one stable key. So `doma add ~/dotfiles` and `doma add /Users/me/dotfiles` are the same row.

## Tags are many-to-many

A directory can have any number of tags; a tag can cover any number of directories. There's no hierarchy stored anywhere — `work/proj-a` is just a tag whose name happens to contain a `/`. `tags --tree` renders that visually but doesn't impose structure.

```
crystal     →  /a/proj-1, /a/proj-2, /b/sandbox
work/auth   →  /work/auth-svc
work/billing→  /work/billing-svc
```

This means: tag the same directory under multiple lenses (`crystal`, `work/proj-a`, `weekly-spike`) and use whichever one fits the current task.

## Frecency

Every successful `--pick` (or `doma cd`) bumps `last_used_at` on the chosen directory. That timestamp drives:

- The picker's default order (most-recently-used first).
- `doma list --by recent`.
- The **Most used** section in `doma stats`.

You don't have to think about it — using doma trains it.

## TTL: tags can expire

Most tags are durable (`crystal`, `work/proj-a`). Some are transient (`bookmark`, `code-review`, `weekly-spike`). doma supports both: any tag can carry a TTL, after which it's hidden from queries automatically. The directory itself stays put — only that one tag binding expires.

```bash
doma add . -t bookmark --ttl 7d   # bookmark expires in 7 days
doma mark spike                   # shorthand: cwd, 7-day TTL
```

Re-tagging refreshes the clock. Adding a tag without `--ttl` makes it permanent. See [TTL & marks](../../usage/ttl-and-marks/) for the full mechanics.

## Soft delete

`doma rm <path>` doesn't immediately destroy the row — it goes into a trash store under `~/.config/doma/trash/`, recoverable for 7 days via `doma trash list` / `doma trash restore <id>`. Same for `prune --gone`.

This matters in two real cases:

1. An external disk got unplugged → `prune --gone` would mark everything on it as missing, but `trash restore` brings it all back.
2. You typo'd an `rm` → 7 days to undo.

`--hard` skips the trash for when you really do want it gone.

## Path source for the rest of your shell

doma is designed to compose with everything you already use. Most commands have a flag for parseable output:

```bash
doma list -t TAG --paths    # newline-separated, for `while read` / xargs
doma list -t TAG -0         # NUL-separated, safe for paths with spaces
doma list -t TAG --json     # structured: short_id, path, tags, expirations
doma list -t TAG --pick     # exactly one path on stdout
```

That last one is what makes `doma cd` possible — and the same primitive an AI agent uses when it needs to operate across "all my X projects".

## Where data lives

Single SQLite file: `~/.config/doma/doma.db`. Override with `DOMA_DB`. Strict YAML config at `~/.config/doma/config.yml` (optional — defaults are sensible). Trash store under `~/.config/doma/trash/`. Schema migrations run transparently on open (`PRAGMA user_version`).

`doma doctor` prints all of this in one shot when you want to know what doma's actually doing.

## What doma is *not*

- **Not a directory autojump tool.** zoxide / autojump / z infer "where you've been" from `cd` history. doma asks you to label deliberately. The flip side: precision instead of guess.
- **Not a workspace manager.** No project files, no init scripts, no env loading. doma resolves a path; what you do there is up to your shell.
- **Not a sync tool.** State is local. [Snapshots](../../usage/snapshots/) make it portable, but there's no built-in cloud.

## Next

- [Quickstart](../quickstart/) — five-minute hands-on tour
- [Comparison](../comparison/) — vs zoxide / autojump / fzf / fasd
- [Tagging directories](../../usage/tagging/) — auto-tags, git remote derivation, glob filters
