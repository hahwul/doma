+++
title = "Search & stats"
description = "Substring search across paths and tags, plus the stats summary."
weight = 6
+++

## Search

```bash
doma list <query>
```

Case-insensitive substring match across the canonical path, the basename, and every active tag name:

```bash
doma list auth                # any path/tag containing "auth"
doma list -t crystal auth     # crystal-tagged AND containing "auth"
```

Path/basename hits show up regardless of tag state; tag-name hits skip expired rows.

## Glob filtering on tags

```bash
doma list -t 'work/*'                            # every tag like work/proj-a, work/proj-b
doma list -t 'work/**'                           # every tag under work/, any depth
doma list -t 'work*' --pick --first --by recent  # most-recent matching dir on stdout
```

`*`, `**`, and `?` in a tag argument switch matching from exact-equal to glob:

- `*` matches within one segment (doesn't cross `/`)
- `**` matches across `/`
- `?` matches a single non-`/` character

Quote the pattern to keep your shell from expanding it first.

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

- Total directories and total tags.
- Top tags by usage count (`--top N`).
- Most recently *added* paths (`--recent N`).
- Most recently *used* paths via `cd` frecency (`--used N`).

`--json` emits the same data structured.
