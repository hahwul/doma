+++
title = "Quickstart"
description = "Tag a directory, navigate to it, and operate on the whole pile in five commands."
weight = 2
+++

A five-minute tour of the commands you'll actually use.

## 1. Tag a directory

```bash
cd ~/Projects/doma
doma add . -t crystal -t cli
```

`add` defaults to the current directory when you don't pass a path. Tags can repeat (`-t a -t b`) or be comma-separated (`-t a,b`).

## 2. List what's on the board

```bash
doma list
```

You'll see one line per directory:

```
0dc0db9  /Users/me/Projects/doma   #cli #crystal
```

The first column (`0dc0db9`) is a stable short_id. The path is the canonical real path (symlinks resolved). Tags follow as `#name`.

## 3. Jump back to it

```bash
doma cd crystal
```

Multiple matches open an interactive picker — type to filter, ↑↓ to move, Enter to pick. `doma cd` needs the shell wrapper, so run `doma setup install` once if you haven't yet (see [Shell integration](../shell-integration/)).

## 4. Operate on every dir under a tag

```bash
doma run crystal --parallel -- shards build
```

For custom loops, `doma list -t crystal --paths` gives you one path per line (use `-0` for NUL-separated output).

## 5. Mark something for the week

```bash
doma mark spike
```

Shorthand for `doma add . -t spike --tmp` — tags the current directory with a 7-day TTL. Expired tags drop out of `list` automatically.

## Where to go next

- [Shell integration](../shell-integration/) — make `doma cd` actually change directory
- [Tagging directories](../../usage/tagging/) — auto-tags, git remote derivation, glob filters
- [Pipelines](../../usage/pipelines/) — composing doma with `xargs`, `jq`, and friends
