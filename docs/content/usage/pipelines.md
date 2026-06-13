+++
title = "Pipelines"
description = "Compose doma with xargs, jq, and the rest of your shell toolbox."
weight = 7
+++

doma is designed as a path source — most commands have a flag that emits a parseable form.

## Output modes for `list`

| Flag | Output | Best for |
|---|---|---|
| `--paths` | one path per line | `while read`, `xargs`, `awk` |
| `-0` / `--print0` | NUL-separated paths | `xargs -0` (paths with spaces) |
| `--json` | structured JSON array | `jq`, scripts that need short_id / tags |
| (default) | aligned text with short_id + tags | humans |

`-0` implies `--paths`.

## Common shapes

### while-read loop

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

### Top 5 by recency

```bash
doma list --by recent --paths | head -5
```

## Tags-only pipelines

```bash
doma tags --names                     # one tag per line
doma tags -0 | xargs -0 ...           # NUL-separated
doma tags --json | jq -r '.[] | select(.count > 5) | .name'
```

## What doesn't compose

`doma list --pick` is interactive when there's more than one match. In a pipeline it falls back to first-match with a stderr advisory — for deterministic resolution pass `--first`, narrow the filter, or skip `--pick` and select yourself with `list --paths`.

`doma run` produces decorated stderr that's hard to parse; for machine-readable per-directory results, drive the loop yourself.
