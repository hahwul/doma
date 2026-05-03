+++
title = "TTL & marks"
description = "Temporary tags that expire on their own, and the mark shorthand for the everyday case."
weight = 3
+++

Some tags are durable organization (`crystal`, `work/proj-a`); others are transient — bookmarks during a code review, a debugging session, a week of reading. doma supports both as the same kind of tag with an optional time-to-live.

## Adding with a TTL

```bash
doma add . -t bookmark --ttl 7d
doma add . -t bookmark --ttl 30m
doma add . -t bookmark --ttl 2w
```

Accepted units: `s`, `m`, `h`, `d`, `w`. Single number + single unit. No compound like `1d2h`.

`--tmp` is shorthand for `--ttl 7d`:

```bash
doma add . -t bookmark --tmp
```

## The `mark` shortcut

The most common case is "tag the current directory for a week":

```bash
doma mark bookmark
```

That's exactly equivalent to `doma add . -t bookmark --tmp`, just shorter. Multiple tags work:

```bash
doma mark spike skim review
```

To mark a path other than the current directory, use `-p`:

```bash
doma mark -p ~/Projects/sandbox spike
```

For a custom TTL, fall back to `doma add --ttl` directly.

## What "expired" means

When a tag's `expires_at` is in the past, the row is **hidden** from queries by default:

- `doma list -t TAG` doesn't show it.
- `doma list -t TAG --pick` (and the `doma cd TAG` shell wrapper that calls it) won't resolve via it.
- The directory itself is unaffected — if it has other (non-expired) tags, it still appears under those.

Expired rows aren't deleted on their own. Two reasons:

1. Re-tagging a path *refreshes* the TTL — `doma add . -t bookmark --tmp` resets the clock to 7 days from now. The row needs to still be there for the update to land.
2. You can audit what expired with `--include-expired`:

```bash
doma list --include-expired
```

## Cleaning up

To physically remove every expired tag row:

```bash
doma prune --expired
```

That's a maintenance op — it deletes the `directory_tags` rows whose TTL has elapsed and garbage-collects any tags left with no rows. Directories themselves are preserved. (Sister command: `doma prune --gone` for entries whose path no longer exists on disk.)

## Re-tag semantics

Re-tagging a path with `add` is the **source of truth** for that tag's lifetime:

```bash
doma add . -t bookmark --ttl 7d   # expires in 7 days
doma add . -t bookmark --tmp      # expires in 7 days (refreshed)
doma add . -t bookmark            # now permanent (expires_at cleared)
```

The last form is occasionally useful: "this thing I marked for the week — actually keep it."

## When to use `mark` vs `add --ttl`

| Use case | Command |
|---|---|
| "I'll come back to this for the week" | `doma mark <name>` |
| "Bookmark these for a code review" | `cd` into each, `doma mark code-review` |
| "Keep this for two days" | `doma add . -t reading --ttl 2d` |
| "Track this project long-term" | `doma add . -t crystal` (no TTL) |

`mark` is the limited form — positional tag list, 7-day TTL, cwd by default with `-p` for an explicit path. Anything beyond that uses `add` directly.
