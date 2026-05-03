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
✓ /Users/me/Projects/sandbox (exit 0)
```

## Parallel

```bash
doma run crystal --parallel -- shards build
```

A fiber per directory; per-directory exit reports come at the end. Best for summary-style output rather than rich live logs.

## Failure handling

```bash
doma run crystal --fail-fast -- crystal spec
```

`--fail-fast` halts the loop on the first non-zero exit (sequential only — parallel always runs every directory to completion). doma's exit code reflects the failure.

## When to reach for `run` vs a manual loop

Use `doma run` when the operation is a single shell command and per-directory logic is uniform.

Use `doma list -t TAG --paths | while read` when you need per-directory inspection or want to feed paths into another tool. See [Pipelines](../pipelines/).
