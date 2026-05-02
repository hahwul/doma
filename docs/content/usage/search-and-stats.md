+++
title = "Search & stats"
description = "Substring search across paths and tags, plus the stats summary."
weight = 5
+++

## Search

```bash
doma list <query>
```

The positional argument is a substring search across:

- the canonical path,
- the directory's basename,
- and every active tag name on it.

```bash
doma list auth                # any path/tag containing "auth"
doma list -t crystal auth     # crystal-tagged AND containing "auth"
```

The match is case-insensitive. SQL `LIKE` meta-characters (`%`, `_`) in the query are treated literally — search for `100%` finds the literal string, not "anything".

Path/basename hits show up regardless of tag state; tag-name hits filter out expired rows automatically (a search for `bookmark` won't surface paths whose `bookmark` tag has elapsed).

## Glob filtering on tags

```bash
doma list -t 'work/*'                         # every path whose tag matches the glob
doma list -t 'work*' --pick --first --by recent  # most-recent matching dir on stdout
```

`*` and `?` in a tag argument switch matching from exact-equal to SQLite GLOB. Unquote at your own risk — your shell may expand the glob first; quoting is the safe form.

## Listing tags

```bash
doma tags                     # every tag with a usage count
doma tags --names             # just the names (one per line, scriptable)
doma tags --tree              # group by `/` prefix
```

`--tree` groups hierarchically:

```
work/    2
  ├─ proj-a    1
  └─ proj-b    1

crystal    3
home    1
```

## Stats

```bash
doma stats
```

Prints a summary view:

- Total directories and total tags.
- Top tags by usage count (`--top N` to widen).
- Most recently *added* paths (`--recent N`).
- Most recently *used* paths via `cd` frecency (`--used N`).

For scripting, `--json` emits the same data structured.

## Doctor

```bash
doma doctor
```

Not really a stats command, but adjacent: reports doma's database location, size, schema version, and how many entries are tracking now-missing paths. A clean baseline for "is doma healthy" checks.

## Cleanup

```bash
doma prune --gone        # entries whose path no longer exists on disk
doma prune --gone --hard # same, but skip the trash (permanent)
doma prune --expired     # tag rows whose TTL has elapsed
```

Both are bulk-only operations — they refuse to combine and have no per-path form by design (use `rm <path>` for targeted deletion). Run them when the report from `doctor` shows drift.

By default, `prune --gone` writes the dropped entries to the trash so a briefly-unmounted external disk doesn't permanently destroy tags — recover with `doma trash list` / `doma trash restore <id>` for 7 days. Pass `--hard` to skip that snapshot when you really do want the rows gone.
