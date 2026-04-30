+++
title = "Commands"
description = "All doma subcommands at a glance."
weight = 1
+++

| Command | Purpose |
|---|---|
| `add [<path>]` | Register a path (defaults to `.`) with one or more tags. |
| `mark <tag> ...` | Tag cwd with temporary (7-day) tags. Alias for `add . -t TAG ... --tmp`. |
| `rm <path>` | Remove tag(s) from a path, or drop the path entirely (single-target). |
| `prune --gone\|--expired` | Bulk-delete entries whose path is missing, or tag rows past their TTL. |
| `move <old> <new>` | Move a registered path; tags carry over. |
| `tags` | List all tags with usage counts. |
| `rename <old> <new>` | Rename a tag, or merge into an existing one. |
| `list [<query>]` | List or search directories (`--pick` to resolve to one path). |
| `info [<path>]` | Show one entry's details (tags, TTLs, last-used). Defaults to cwd. |
| `stats` | Top tags + recently added/used paths. |
| `run <tag> -- <cmd>` | Run a command in every tagged directory. |
| `export` | Dump the database (JSON or YAML). |
| `import <file>` | Load a snapshot (`--merge` or `--replace`). |
| `setup install` | Append the shell wrapper to your rc file. |
| `setup init <shell>` | Print the shell wrapper for manual install. |
| `setup completion <shell>` | Print a shell completion script. |
| `doctor` | Check the install (paths, config, DB). |
| `version` / `help` | Show version / help. |

`doma cd <tag>` lives in the shell wrapper installed by `setup install`, not in the binary itself.

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
doma rm <path> [<path> ...] [-t TAG ...] [--hard]
```

- `<path>` alone: drop the path and all its tags (snapshotted to trash by default).
- `<path> -t TAG`: untag the path (path entry remains if other tags are present).
- `--hard`: skip the trash and delete permanently.

For bulk cleanup (sweep missing paths, prune expired tag rows), use `doma prune` — split out so the per-path `rm` form can't accidentally trip a sweep.

## `prune`

```
doma prune (--gone | --expired)
```

- `--gone`: remove every entry whose path no longer exists on disk. Trash-skipping by design (the original directory is already gone, so there's nothing to restore to).
- `--expired`: drop tag rows whose TTL has elapsed and GC any tags left with no rows. Directories themselves are preserved.

The two flags are mutually exclusive — each sweep has its own intent.

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
- `--pick`: resolve to a single path on stdout (interactive on TTY,
  most-recent first off-TTY with a stderr advisory). The shell wrapper
  installed by `doma setup install` builds `doma cd <tag>` on top of
  this. Composes with `--query Q`, `--first` (deterministic auto-pick,
  no prompt), and `--builtin` (force the picker even off-TTY).

The bare binary does **not** ship a `cd` subcommand. Calling
`doma cd …` directly errors and points at `doma setup install` (or
the `cd "$(doma list -t TAG --pick)"` inline form for scripts).

## `info`

```
doma info [<path>] [--json]
```

Single-entry detail view. The path defaults to `.` so `doma info` from inside a project answers the most common question — "did I tag this directory? with what?" — in one keystroke.

Output: short_id, canonical path, basename, every tag (with TTL remaining or `~expired` suffix), `created_at`, `last_used_at`, and an `exists` check against the filesystem. Exits 3 when the path isn't registered, with a hint that points at `doma add`.

`--json` emits the same fields plus an `expirations` map (`tag_name → unix_epoch`) when any tag has a TTL.

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
doma setup completion <bash|zsh|fish>
```

`install` auto-detects from `$SHELL`; pass an explicit name to override. Installs the `doma cd` shell function (a child process can't change its parent shell's cwd, so the function lives in your shell rather than the binary).

## `doctor`

```
doma doctor
```

Reports paths (home / config / DB), config-file status, and database stats (directories, tags, missing-on-disk count, schema version). Run this first if anything looks off.
