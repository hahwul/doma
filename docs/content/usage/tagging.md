+++
title = "Tagging directories"
description = "Add tags to directories, derive them automatically from basename or git remote, and manage them as your collection grows."
weight = 1
+++

## Basics

```bash
doma add /path/to/dir -t TAG [-t TAG ...]
```

Path defaults to `.`:

```bash
cd ~/Projects/doma
doma add -t crystal -t cli
```

Multiple paths in one shot:

```bash
doma add /a /b /c -t shared
```

Validation failures on one path don't block the others — doma exits non-zero and reports the failed path on stderr.

## Tag rules

A valid tag is `[A-Za-z0-9][A-Za-z0-9_.\-+:/]{0,63}` — starts with a letter or digit, 1–64 bytes, allows `_ . - + : /`. Whitespace and commas are rejected (commas are reserved as a CLI separator: `-t a,b,c` adds three tags).

`/` in tag names gets special treatment in `doma tags --tree`, which groups `work/proj-a` and `work/proj-b` under a `work/` header.

## Auto-derived tags

```bash
doma add . --auto-tag       # tag with the directory's basename
doma add . --git-tag        # tag with the git remote host + repo (if any)
doma add . --auto-tag --git-tag
doma add . --project-tag    # tag by project type: shard.yml → crystal, Cargo.toml → rust, …
```

`--git-tag` reads `.git/config`'s `[remote "origin"]` and derives a host tag (`github`, `gitlab`, `bitbucket`, `codeberg`, or the raw hostname for self-hosted) and the repo name.

Auto-derived tags are sanitized — `.dotfiles` becomes `dotfiles`. If sanitization can't produce a valid tag, the auto-tag is silently skipped.

Defaults are configurable in [config](../../reference/config/).

## Registering a whole tree

```bash
doma add -r ~/Projects --project-tag -n    # preview
doma add -r ~/Projects --project-tag       # every git repo under ~/Projects, tagged by type
doma add -r ~/work -t work --git-tag       # flags apply to each repo found
```

`-r` replaces each path with the git repos at or under it. A repo is a leaf: submodules and checkouts nested inside it aren't listed. Hidden directories, `node_modules` / `vendor` / `target` / `dist` / `build`, and symlinks are skipped; the walk stops 4 levels down.

## Re-tagging

`add` is idempotent on path — second call doesn't duplicate, it merges:

```bash
doma add . -t alpha     # path now tagged: alpha
doma add . -t beta      # path now tagged: alpha, beta
```

To remove:

```bash
doma rm /path -t alpha   # untag
doma rm /path            # drop the path entirely (and all its tags)
```

## Renaming and merging

```bash
doma rename old-name new-name
```

Simple rename if `new-name` doesn't exist; otherwise the two are merged in one transaction.

## Moving paths

```bash
doma move /old/path /new/path
```

Tags carry over. If `/new/path` is already registered, the two are merged. `--allow-missing` skips the existence check on the destination — useful for cross-machine snapshots.

## Dry run

```bash
doma add . -t crystal --auto-tag --git-tag --dry-run
```

Resolves the tag set without writing.
