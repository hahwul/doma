+++
title = "Pipelines"
description = "Compose doma with xargs, jq, and the rest of your shell toolbox."
weight = 6
+++

doma is designed as a path source. Most of its commands have a flag that emits a parseable form, so chaining is straightforward.

## Output modes for `list`

| Flag | Output | Best for |
|---|---|---|
| `--paths` | one path per line | `while read`, `xargs`, `awk` |
| `-0` / `--print0` | NUL-separated paths | `xargs -0` (paths with spaces) |
| `--json` | structured JSON array | `jq`, scripts that need short_id / tags |
| (default) | aligned text with short_id + tags | humans |

`-0` implies `--paths`, so `doma list -t crystal -0 | xargs -0 ...` is the short form.

## Common shapes

### Iterate with a while-read loop

```bash
doma list -t crystal --paths | while read -r dir; do
  (cd "$dir" && git pull)
done
```

### NUL-safe xargs

```bash
doma list -t crystal -0 | xargs -0 -I{} sh -c 'cd "{}" && shards build'
```

### Filter with jq

```bash
doma list --json | jq -r '.[] | select(.tags | index("crystal")) | .path'
doma list --json | jq -r '.[] | "\(.short_id)\t\(.path)"'
```

### Sort by recency, take top 5

```bash
doma list --by recent --paths | head -5
```

### Combine with `find` for content searches

```bash
doma list -t crystal -0 | xargs -0 -I{} grep -l "TODO" {}/src/**/*.cr
```

## Tags-only pipelines

```bash
doma tags --names                     # one tag per line
doma tags -0 | xargs -0 ...           # NUL-separated
doma tags --json | jq -r '.[] | select(.count > 5) | .name'
```

## SIGPIPE and exit codes

doma cooperates cleanly with pipelines that close their input early:

```bash
doma list --json | head -c 1
```

Without special handling that would surface as `internal error: Broken pipe`. doma instead exits 141 (the SIGPIPE convention) silently, so chained `set -e` scripts can still detect actual failures upstream.

## What doesn't compose

`doma list --pick` is interactive when there's more than one match. In a pipeline (no TTY on stdin) it falls back to "first match" automatically with a stderr advisory, but that may not be what you want. For deterministic resolution, pass `--first` explicitly, narrow the filter (`-t`/`--query`/positional substring), or skip `--pick` and drive selection yourself with `list --paths`.

`doma run` produces decorated stderr output that's hard to parse mechanically. If you need machine-readable per-directory results, drive the loop yourself with `list --paths` and capture exit codes from the inner command.
