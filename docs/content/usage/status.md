+++
title = "Git status"
description = "See the working-tree state of every repo under a tag at a glance."
weight = 5
+++

```bash
doma status [<tag>]
```

`status` is the read-only twin of [`run`](../run/): where `run` executes a command across a tagged set, `status` reports each directory's git state — branch, ahead/behind vs upstream, and a dirty-file count — in one table.

```
$ doma status work
/Users/me/work/api      ✔ clean            main      ↑2
/Users/me/work/web      ● 3 dirty          feat/x    ↓1 ↑4
/Users/me/work/docs     ✗ not a git repo
/Users/me/work/legacy   ✗ gone

4 repos · 1 dirty · 1 ahead · 1 gone
```

With no tag, every tracked directory is scanned. Pass a tag (positionally or with `-t`) to narrow; tag globs work the same as `run`/`list` (`doma status 'work/*'`).

## What each column means

| Column | Meaning |
|---|---|
| `✔ clean` | git repo, nothing uncommitted |
| `● N dirty` | N changed paths (modified + untracked + conflicts) |
| `✗ not a git repo` | tracked, on disk, but no git working tree |
| `✗ gone` | path no longer exists — run `doma prune --gone` |
| branch | current branch, or `(detached)` for a detached HEAD |
| `↓N ↑M` | N commits behind / M ahead of upstream (omitted when in sync or no upstream) |

## Just the dirty ones

```bash
doma status work --dirty
```

`--dirty` hides everything clean, leaving only repos with uncommitted work — the fast answer to "what did I leave unfinished across all my work repos?"

## Speed

Each directory is probed with one `git status` call, run in parallel (CPU-count workers by default). Tune with `--jobs N` on slow disks or very large sets:

```bash
doma status --jobs 4
```

`status` shells out to your installed `git`; if git isn't on `PATH` it stops with a single clear error rather than reporting every repo as a non-repo.

## Scripting

```bash
doma status work --json | jq -r '.[] | select(.dirty > 0) | .path'
```

The JSON form carries the full breakdown per entry — `branch`, `upstream`, `ahead`, `behind`, `modified`, `staged`, `unstaged`, `untracked`, `conflicts`, `dirty`, `clean`, plus `exists`/`git` flags for non-repo and missing paths.
