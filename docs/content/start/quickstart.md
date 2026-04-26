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

If you have one match it prints the path. With multiple matches you get an interactive picker — type to filter, ↑↓ to move, Enter to pick. **Without the shell wrapper, `doma cd` only prints the path; see [Shell integration](../shell-integration/) for the one-line setup.**

You can also jump by short_id, including a unique prefix:

```bash
doma cd 0dc0db9    # full
doma cd 0d         # prefix, if no other dir starts with 0d
```

## 4. Operate on every dir under a tag

```bash
doma list -t crystal --paths | while read -r d; do
  (cd "$d" && shards build)
done
```

`--paths` gives you one path per line, ideal for `while read` and `xargs`. Use `-0` instead of `--paths` for NUL-separated output (safe for paths with spaces).

There's also a built-in form:

```bash
doma run crystal --parallel -- shards build
```

## 5. Mark something for the week

For transient bookmarks during a code-review or debugging session:

```bash
doma mark spike
```

That's an alias for `doma add . -t spike --tmp` — it tags the current directory with a 7-day TTL. Expired tags vanish from `list` automatically; permanent tags on the same directory are unaffected.

## Where to go next

- [Shell integration](../shell-integration/) — make `doma cd` actually change directory
- [Tagging directories](../../usage/tagging/) — auto-tags, git remote derivation, glob filters
- [Pipelines](../../usage/pipelines/) — composing doma with `xargs`, `jq`, and friends
