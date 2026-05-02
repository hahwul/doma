+++
title = "Tagging directories"
description = "Add tags to directories, derive them automatically from basename or git remote, and manage them as your collection grows."
weight = 1
+++

## Basics

```bash
doma add /path/to/dir -t TAG [-t TAG ...]
```

Path defaults to `.`, so this is the typical form:

```bash
cd ~/Projects/doma
doma add -t crystal -t cli
```

Multiple paths in one shot:

```bash
doma add /a /b /c -t shared
```

If one path fails validation (doesn't exist, isn't a directory) the others still get committed. doma exits non-zero and reports the failed path on stderr.

## Tag rules

A valid tag is `[A-Za-z0-9][A-Za-z0-9_.\-+:/]{0,63}`:

- Must start with a letter or digit.
- Allowed: letters, digits, `_`, `.`, `-`, `+`, `:`, `/`.
- 1 to 64 bytes long.

`/` in tag names is allowed and gets special treatment in `doma tags --tree`, which groups `work/proj-a` and `work/proj-b` under a `work/` header.

Whitespace, commas, and other punctuation are rejected. Comma is reserved as a separator on the CLI side: `-t a,b,c` adds three tags.

## Auto-derived tags

```bash
doma add . --auto-tag       # tag with the directory's basename
doma add . --git-tag        # tag with the git remote host + repo (if any)
doma add . --auto-tag --git-tag
```

`--auto-tag` adds the basename. `--git-tag` reads `.git/config`'s `[remote "origin"]` and derives:

- a host tag (`github`, `gitlab`, `bitbucket`, `codeberg`, or the raw hostname for self-hosted)
- the repo name

Auto-derived tags are sanitized — a `.dotfiles` repo's `.dotfiles` basename becomes `dotfiles` rather than failing validation. If sanitization can't produce a valid tag (e.g. `...`), the auto-tag is silently skipped.

You can flip these defaults in [config](../../reference/config/).

## Re-tagging

`doma add` is idempotent on path: the second call doesn't duplicate. New tags are merged in:

```bash
doma add . -t alpha     # path now tagged: alpha
doma add . -t beta      # path now tagged: alpha, beta
```

To remove a tag from a path:

```bash
doma rm /path -t alpha
```

To drop the path (and every tag on it) entirely:

```bash
doma rm /path
```

## Renaming and merging tags

```bash
doma rename old-name new-name
```

If `new-name` doesn't exist, this is a simple rename. If it already exists, the two are merged: every directory tagged `old-name` becomes tagged `new-name`, then `old-name` is dropped. The whole operation is one transaction.

## Moving paths

If a directory moves on disk, update doma so its tags follow:

```bash
doma move /old/path /new/path
```

Tags carry over. If `/new/path` is already registered with its own tags, the two are merged.

`--allow-missing` skips the existence check on the destination — useful for cross-machine snapshots where the local filesystem differs.

## Dry-run preview

```bash
doma add . -t crystal --auto-tag --git-tag --dry-run
```

Resolves the tag set (user + auto + git) without writing. Same exit-code semantics as a real run, so you can use it in scripts.
