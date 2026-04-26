+++
title = "Commands"
description = "All doma subcommands at a glance."
weight = 1
+++

| Command | Purpose |
|---|---|
| `add [<path>]` | Register a path (defaults to `.`) with one or more tags. |
| `mark <tag> ...` | Tag cwd with temporary (7-day) tags. Alias for `add . -t TAG ... --tmp`. |
| `rm <path>` | Remove tag(s) from a path, or drop the path entirely. |
| `move <old> <new>` | Move a registered path; tags carry over. |
| `tags` | List all tags with usage counts. |
| `rename <old> <new>` | Rename a tag, or merge into an existing one. |
| `list [<query>]` | List or search directories. |
| `cd [<tag>\|<id>]` | Resolve a directory (interactive picker on multiple matches). |
| `stats` | Top tags + recently added/used paths. |
| `run <tag> -- <cmd>` | Run a command in every tagged directory. |
| `export` | Dump the database (JSON or YAML). |
| `import <file>` | Load a snapshot (`--merge` or `--replace`). |
| `setup install` | Append the shell wrapper to your rc file. |
| `setup init <shell>` | Print the shell wrapper for manual install. |
| `setup doctor` | Check the install (paths, config, DB). |
| `version` / `help` | Show version / help. |

## Global flags

| Flag | Effect |
|---|---|
| `-q`, `--quiet` | Suppress success/info output (errors still print). |
| `-v`, `--verbose`, `--debug` | Print debug traces to stderr. |
| `--no-color` | Force color off. |
| `--color` | Force color on (defaults to TTY auto-detect). |

`NO_COLOR` env is honored automatically.

## `add`

```
doma add [<path> ...] [-t TAG ...] [--ttl DUR | --tmp]
                                   [--auto-tag] [--git-tag] [--dry-run]
```

- `-t TAG`: add a tag. Repeatable; comma-separated also works (`-t a,b`).
- `--ttl DUR`: tag expires after `DUR` (e.g. `30s`, `5m`, `1h`, `7d`, `2w`).
- `--tmp`: alias for `--ttl 7d`.
- `--auto-tag` / `--no-auto-tag`: include the basename as a tag.
- `--git-tag` / `--no-git-tag`: derive `git`, host, and repo tags from `.git/config`.
- `-n`, `--dry-run`: resolve and print without writing.

Path defaults to `.` if omitted. Multiple paths are accepted; partial success on validation errors.

## `mark`

```
doma mark <tag> [<tag> ...]
```

Equivalent to `doma add . -t TAG ... --tmp`. cwd only, 7-day default. For other paths or custom TTL, use `add` directly.

## `rm`

```
doma rm [<path> ...] [-t TAG ...] [--gone] [--expired]
```

- `<path>` alone: drop the path and all its tags.
- `<path> -t TAG`: untag the path (path entry remains if other tags are present).
- `--gone`: remove every entry whose path no longer exists on disk. Mutually exclusive with explicit paths/tags.
- `--expired`: prune all expired tag rows + GC orphan tags. Mutually exclusive too.

## `list`

```
doma list [<query>] [-t TAG] [--by path|recent]
                    [--check] [--include-expired]
                    [--json] [--paths] [-0]
```

- `<query>`: substring match across path/basename/tag.
- `-t TAG`: exact tag (or glob if `*` / `?` is present).
- `--by`: sort by `path` (default) or `recent` (last-used).
- `--check`: annotate entries whose path is gone with `[gone]`.
- `--include-expired`: include tag rows whose TTL has elapsed.
- `--json` / `--paths` / `-0`: machine-readable forms (see [Pipelines](../../usage/pipelines/)).

## `cd`

```
doma cd [<tag>|<short-id>] [--first | --builtin | --index N] [--query Q]
```

- Bare positional: tag name first, then short_id prefix.
- `--first`: skip the picker, take the most-recent match.
- `--builtin`: force the interactive picker even when stdin isn't a TTY.
- `--index N`: 1-based index into the (recency-ordered) match set.
- `--query Q`: pre-fill the picker filter (no-tag mode).

Without a positional: browses every registered directory.

## `run`

```
doma run <tag> [--fail-fast] [--parallel] -- <cmd> [args...]
```

`--` is required. `--fail-fast` is sequential-only.

## `export` / `import`

```
doma export [--json | --yaml] [-o FILE]
doma import <file> [--merge | --replace] [-y | --yes]
```

`--replace` without `--yes` requires a TTY confirmation; in non-interactive contexts it refuses.

## `setup`

```
doma setup install [<shell>] [-y | --yes] [-n | --dry-run]
doma setup init <bash|zsh|fish>
doma setup doctor
```

`install` auto-detects from `$SHELL`; pass an explicit name to override.
