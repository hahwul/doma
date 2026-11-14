+++
title = "Bulk run"
description = "Execute a command in every directory under a tag, sequentially or in parallel."
weight = 4
+++

```bash
doma run <tag> -- <command> [args...]
```

`--` is required: it separates doma's flags from the user command.

## Sequential (default)

```bash
doma run crystal -- shards build
```

Output streams interleaved with a per-directory header:

```
▶ /Users/me/Projects/doma
…build output…
✓ /Users/me/Projects/doma (exit 0)

▶ /Users/me/Projects/sandbox
…
✗ /Users/me/Projects/sandbox (exit 1)

1 ok · 1 failed
  ✗ /Users/me/Projects/sandbox (exit 1)
```

When more than one directory runs, a tally closes the sweep on stderr and re-lists every failure, so a long sweep's ✗ lines don't scroll away. `--no-header` keeps it only when something failed, `-q` drops it; `--json` never prints it (the rows already carry every exit code).

## Retry what failed (`@failed`)

Every real sweep (not `--dry-run`) records the directories that exited non-zero. `@failed` selects them, so the fix-and-retry loop needs no copy-pasting:

```bash
doma run crystal -- crystal spec      # 2 failed
# …fix things…
doma run @failed -- crystal spec      # only those 2; whatever still fails stays in @failed
doma list -t @failed --paths          # or inspect them
```

The other built-in sets come from git, probed at selection time: `@dirty` (uncommitted changes — `doma run work -t @dirty -- git stash`), `@ahead` / `@behind` (vs the upstream as of the last fetch; a branch with no upstream is in neither — `doma run @ahead -- git push`), and `@unreleased` (commits since the latest tag). Sets combine with tags in `-t` and `-x` anywhere a tag is accepted (`list`, `run`, `status`). Directories `--fail-fast` never reached count as not-yet-passed and land in `@failed` too. Each sweep replaces the previous list, whatever its tag.

## Per-directory environment

Each child gets the entry it runs for in its environment, so per-directory commands need no `{}` templating or `xargs` quoting:

| Variable | Value |
|---|---|
| `DOMA_PATH` | the directory (also the child's cwd) |
| `DOMA_NAME` | its basename |
| `DOMA_ID` | its 7-char `short_id` |
| `DOMA_TAGS` | its active tags, comma-separated |

```bash
doma run crystal -- sh -c 'tar czf "/tmp/backup/$DOMA_NAME.tgz" .'
doma run 'work/*' -- sh -c 'echo "$DOMA_ID $DOMA_TAGS"'
```

## Parallel

```bash
doma run crystal --parallel -- shards build
```

A fiber per directory; per-directory exit reports come at the end. Best for summary-style output rather than rich live logs.

Cap the fan-out with `--jobs N` (default: CPU count). Without a cap, a `git fetch` sweep across 200 repos would open 200 connections at once.

## Machine-readable results (`--json`)

Streaming output merges every directory onto one terminal. That's fine to read, but it means a script — or an AI agent — can't tell which repo produced which line, and under `--parallel` the lines interleave arbitrarily. `--json` captures each child's streams separately and emits one row per directory:

```bash
doma run crystal --parallel --json -- shards build
```

```json
[{"path":"/Users/me/Projects/doma","exit_code":0,"stdout":"…\n","stderr":"","dry_run":false},
 {"path":"/Users/me/Projects/sandbox","exit_code":1,"stdout":"","stderr":"…\n","dry_run":false}]
```

Rows come back in the same order as `doma list -t TAG --paths`, regardless of which directory finished first — so two sweeps can be zipped or diffed. Which makes "what actually broke?" a query rather than a squint:

```bash
doma run crystal --json -- shards build | jq -r '.[] | select(.exit_code != 0) | .path'
```

Details:

- The `▶`/`✓` chrome is suppressed — the rows already carry every exit code.
- The process exit code is unchanged: 0 if every directory succeeded, 1 if any failed.
- A directory that no longer exists on disk becomes a row with `exit_code: 127` and doma's explanation in `stderr`, rather than a hard error.
- `--fail-fast` truncates the array to the directories that actually ran.
- stdin is closed for every child (there's no human to answer a prompt in a captured run).

## Preview the target set (`--dry-run`)

```bash
doma run 'work/*' --dry-run -- rm -rf node_modules
```

Prints the directories that *would* be swept — paths on stdout, the summary on stderr — without running anything. Worth doing before any destructive sweep, to confirm the glob resolved to what you expect. `--dry-run --json` gives the same preview as `[{"path":…,"dry_run":true}]`.

## Failure handling

```bash
doma run crystal --fail-fast -- crystal spec
```

`--fail-fast` halts the loop on the first non-zero exit (sequential only — parallel always runs every directory to completion). doma's exit code reflects the failure, and the tally counts the directories it never reached as `skipped`.

## When to reach for `run` vs a manual loop

Use `doma run` when the operation is a single shell command and per-directory logic is uniform.

Use `doma list -t TAG --paths | while read` when you need per-directory inspection or want to feed paths into another tool. See [Pipelines](../pipelines/).
