+++
title = "Snapshots"
description = "Export and import doma's database — for backup, version control, or moving to a new machine."
weight = 8
+++

doma stores its state in a single SQLite file. For backup, version control, or moving between machines, use the snapshot commands — they produce a portable JSON or YAML payload.

## Export

```bash
doma export --json                     # to stdout
doma export --yaml                     # YAML form
doma export --json -o doma.json        # to a file (atomic write)
doma export --portable -o doma.json    # for another machine (see below)
```

The output:

```json
{
  "version": 2,
  "generated_at": 1733000000,
  "entries": [
    { "path": "/Users/me/Projects/doma", "basename": "doma", "tags": ["crystal", "cli"] }
  ]
}
```

### Portable snapshots

A plain export records absolute paths, which only mean something on the machine that wrote them. `--portable` changes two things:

```json
{ "path": "~/Projects/doma", "basename": "doma", "tags": ["crystal", "cli"],
  "remote": "git@github.com:me/doma.git" }
```

- Paths under your home directory are written as `~/…`, so they resolve under whatever home the importing user has.
- Each git repository carries its `origin` URL as `remote`, which `import --clone` uses. Credentials embedded in the URL are stripped. Only a primary checkout gets one: a linked worktree, a submodule, a plain subdirectory of a repo, or a repo whose origin is a relative path is exported without `remote` — recreate those with `git worktree add` / `git submodule update` after the clone.

Nothing else differs — a portable snapshot imports on older doma versions too (they ignore `remote`).

## Import

```bash
doma import doma.json                  # merge with existing data
doma import doma.json --replace        # wipe DB first, then import
```

The whole import runs in one transaction — a malformed entry rolls everything back.

`--replace` requires `--yes` when stdin isn't a TTY:

```bash
doma import doma.json --replace --yes
```

Import skips the "directory exists on disk" check: a snapshot from machine A may reference paths machine B doesn't have, and those entries are registered anyway (`doma list --check` marks them `[gone]`). An entry with an invalid tag or a non-absolute path is warned about and skipped.

### Cloning what's missing

```bash
doma import doma.json --clone             # register, then git clone what isn't on disk
doma import doma.json --clone --dry-run   # show what would be cloned
```

After the import, `--clone` runs `git clone <remote> <path>` for every entry that has a `remote` (from `export --portable`) and isn't on disk yet (missing, or an empty directory) — one at a time, parent paths first. Entries that already exist are left alone, so re-running is safe. A failed clone is reported, anything nested under it is skipped, the rest continue, and the command exits 1; the entries stay registered either way.

Without `--clone`, import tells you how many entries could have been cloned.

`--clone` runs `git clone` on URLs taken from the file, so only use it with a snapshot you trust. (doma keeps git's command-running `ext::` transport disabled for these clones, but a URL can still point anywhere.)

## Use cases

### Backup before a risky operation

```bash
doma export --json -o ~/doma-backup-$(date +%F).json
```

### Version-control your tagging

Commit a portable snapshot into a dotfiles repo. Re-apply on a fresh checkout:

```bash
doma export --portable -o ~/dotfiles/doma.json
doma import ~/dotfiles/doma.json --replace --yes --clone
```

### Move to a new machine

```bash
doma export --portable -o doma.json       # old machine
doma import doma.json --clone             # new machine: labels + repositories
```

### Diff two snapshots

```bash
diff <(doma export --json) doma-yesterday.json
```

## Schema versioning

The `version` field protects forward-compat — doma refuses to import snapshots from a newer schema. Lower versions are still readable.
