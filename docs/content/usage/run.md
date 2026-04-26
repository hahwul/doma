+++
title = "Bulk run"
description = "Execute a command in every directory under a tag, sequentially or in parallel."
weight = 4
+++

```bash
doma run <tag> -- <command> [args...]
```

The `--` is required: it tells doma where its own flags end and the user command starts.

## Sequential (default)

```bash
doma run crystal -- shards build
```

doma chdirs into each tagged directory and runs the command. Output streams interleaved with a per-directory header so you can tell whose lines are whose:

```
▶ /Users/me/Projects/doma
…build output…
✓ /Users/me/Projects/doma (exit 0)

▶ /Users/me/Projects/sandbox
…
✓ /Users/me/Projects/sandbox (exit 0)
```

## Parallel

```bash
doma run crystal --parallel -- shards build
```

Spawns a fiber per directory. Output interleaves; per-directory exit reports come at the end. Best for commands whose output is summary-style (counts, exit codes) rather than rich logs you'd want to read live.

`--fail-fast` is honored only in sequential mode — in parallel, every spawned command runs to completion before doma exits.

## Failure handling

```bash
doma run crystal --fail-fast -- crystal spec
```

In sequential mode, `--fail-fast` halts the loop the first time a command exits non-zero. The doma process exit code reflects the failure.

If the command itself can't be launched (binary not found, chdir failure), doma reports it with a sentinel exit code (127 for not-found, 126 for permission/IO error) and continues with the next directory unless `--fail-fast` is set.

## When to reach for `run` vs a manual loop

Use `doma run` when:

- The operation is a single shell command (`shards build`, `git pull`).
- Per-directory logic is uniform.
- You want doma's headers + exit reporting for free.

Use `doma list -t TAG --paths | while read` when:

- You need to inspect each directory before deciding what to do.
- The work involves reading files or making decisions in your script.
- You want to feed the paths into another tool (`xargs`, `parallel`, etc.).

See [Pipelines](../pipelines/) for the loop pattern.
