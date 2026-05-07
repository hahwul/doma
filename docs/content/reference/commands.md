+++
title = "Commands"
description = "All doma subcommands at a glance."
weight = 1
+++

| Command | Purpose |
|---|---|
| `add [<path>]` | Register a path (defaults to `.`) with one or more tags. |
| `mark [-p <path>] <tag> ...` | Tag a directory with temporary (7-day) tags. Defaults to cwd. |
| `rm <path>` | Remove tag(s) from a path, or drop the path entirely. |
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
| `trash <action>` | Recover from `rm` or empty the soft-delete store. |
| `config <action>` | Read or write `config.yml` keys from the CLI. |
| `setup install` | Append the shell wrapper to your rc file. |
| `setup init <shell>` | Print the shell wrapper for manual install. |
| `setup completion <shell>` | Print a shell completion script. |
| `doctor` | Check the install (paths, config, DB). |
| `version` / `help` | Show version / help. |

`doma cd <tag>` lives in the shell wrapper from `setup install`, not in the binary.

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
- `--git-tag` / `--no-git-tag`: derive host and repo tags from `.git/config`.
- `-n`, `--dry-run`: resolve and print without writing.

## `mark`

```
doma mark [-p PATH] (<tag> [<tag> ...] | -t TAG [-t TAG ...])
```

Equivalent to `doma add <path> -t TAG ... --tmp`. Path defaults to cwd; `-p PATH` marks elsewhere. 7-day TTL. Tags accept positional or `-t/--tag`; both forms may be mixed.

## `rm`

```
doma rm <path> [<path> ...] [-t TAG ...] [--hard]
```

- `<path>` alone: drop the path and all its tags (snapshotted to trash by default).
- `<path> -t TAG`: untag.
- `--hard`: skip the trash and delete permanently.

## `prune`

```
doma prune (--gone | --expired) [--hard]
```

- `--gone`: remove entries whose path no longer exists (snapshotted to trash for 7 days; recover with `doma trash list` / `doma trash restore <id>`).
- `--expired`: drop tag rows whose TTL has elapsed and GC any tags left orphaned.
- `--hard`: skip the trash on `--gone`.

The two flags are mutually exclusive.

## `list`

```
doma list [<query>] [-t TAG] [--by path|recent|tag]
                    [--check] [--include-expired]
                    [--json] [--paths] [-0]
                    [--pick [--first | --builtin] [--query Q]]
```

- `<query>`: substring match across path/basename/tag.
- `-t TAG`: exact tag (or glob if `*` / `?` is present).
- `--by`: sort by `path` (default), `recent` (last-used), or `tag` (group output under per-tag headers — entries with multiple tags appear under each; untagged entries collect under `(no tags)`). Incompatible with `--pick`. Under `--json`, the result is an object keyed by tag name (`""` for untagged) instead of a flat array. Under `--paths` / `-0`, paths are emitted in tag-sorted order with duplicates collapsed.
- `--check`: annotate entries whose path is gone with `[gone]`.
- `--include-expired`: include tag rows whose TTL has elapsed.
- `--json` / `--paths` / `-0`: machine-readable forms (see [Pipelines](../../usage/pipelines/)).
- `--pick`: resolve to a single path on stdout. `--first` for deterministic auto-pick, `--builtin` to force the picker even off-TTY.

## `info`

```
doma info [<path-or-short-id>] [--json]
```

Defaults to `.`. Accepts either a path or a short_id (full or unique prefix). Prints short_id, canonical path, tags (with TTL or `~expired` suffix), `created_at`, `last_used_at`, and an `exists` check. Exits 3 when not registered. If the entry is in the trash, surfaces the trash short_id and a restore hint.

## `run`

```
doma run (<tag> | -t TAG) [--fail-fast] [--parallel] -- <cmd> [args...]
```

`--` is required. `--fail-fast` is sequential-only. The tag can be passed positionally or via `-t/--tag` (alias) — pick one. A single tag is accepted; commas are not split, but glob patterns (`*`, `?`) match across multiple tags.

## `export` / `import`

```
doma export [--json | --yaml] [-o FILE]
doma import <file> [--merge | --replace] [-y | --yes]
```

`--replace` without `--yes` requires a TTY confirmation.

## `trash`

```
doma trash list
doma trash restore <short_id> [--merge]
doma trash empty [--older DUR]
```

`rm <path>` writes to the trash by default — `trash list` shows what's recoverable (newest first), `trash restore` brings an entry back. Use `--merge` if the path is already re-registered with different tags. `empty` purges everything; `empty --older 7d` purges only old entries.

Anything older than 7 days is auto-pruned on the next trash op.

## `config`

```
doma config get <key>
doma config set <key> <value>
doma config unset <key>
doma config list
doma config edit
doma config path
```

Keys: `db_path`, `selector`, `auto_tag.basename`, `auto_tag.git` (see [Configuration](../config/) for what each does).

`set` / `unset` rewrite `config.yml` and don't preserve comments — use `config edit` to open the file in `$EDITOR` for hand-edits.

## `setup`

```
doma setup install [<shell>] [-y | --yes] [-n | --dry-run]
doma setup init <bash|zsh|fish>
doma setup completion <bash|zsh|fish>
```

## `doctor`

```
doma doctor
```

Reports paths (home / config / DB), config-file status, and database stats (directories, tags, missing-on-disk count, schema version).
