+++
title = "Snapshots"
description = "Export and import doma's database — for backup, version control, or moving to a new machine."
weight = 7
+++

doma stores its state in a single SQLite file. For everything other than direct copies, use the snapshot commands — they produce a portable JSON or YAML payload that's safe to commit, diff, and restore.

## Export

```bash
doma export --json                     # to stdout
doma export --yaml                     # YAML form
doma export --json -o doma.json        # to a file (atomic)
```

The output includes a schema version, generated-at timestamp, and one entry per directory with its path, basename, tags, and tag TTLs:

```json
{
  "version": 1,
  "generated_at": 1733000000,
  "entries": [
    { "path": "/Users/me/Projects/doma", "basename": "doma", "tags": ["crystal", "cli"] }
  ]
}
```

When writing to a file, doma writes via a temporary file + rename, so a crashed export never replaces an existing good snapshot mid-write.

## Import

```bash
doma import doma.json                  # merge with existing data
doma import doma.json --replace        # wipe DB first, then import
```

The whole import runs inside a single transaction. If anything inside the snapshot fails to apply (malformed entry, schema mismatch), the whole operation rolls back — `--replace` will not leave you with a half-cleared database.

`--replace` requires `--yes` when stdin isn't a TTY:

```bash
doma import doma.json --replace --yes  # CI/script use
```

That's a safety rule: a non-interactive pipeline shouldn't silently destroy state. Interactive runs prompt before replacing.

## Path validation during import

By default, import skips the "directory exists on disk" check that `add` enforces. The reason is portability — a snapshot from machine A may reference paths that machine B doesn't have yet. The import warns about each unimportable entry and continues with the rest:

```
import: skipped /Users/alice/Projects/doma (not a directory)
```

If you want strict validation, pre-filter the snapshot before importing.

## Use cases

### Backup before a risky operation

```bash
doma export --json -o ~/doma-backup-$(date +%F).json
```

### Version-control your tagging

Commit `~/doma.json` (or wherever) into a dotfiles repo. To re-apply on a fresh checkout:

```bash
doma import ~/doma.json --replace --yes
```

### Move to a new machine

Export on the old, scp to the new, import. Paths that don't exist on the new machine are warned and skipped.

### Diff two snapshots

```bash
diff <(doma export --json) doma-yesterday.json
```

JSON keeps the order stable enough that ordinary diff tools work for casual comparison.

## Schema versioning

The snapshot's `version` field is what protects forward-compat. doma refuses to import a snapshot whose `version` is higher than the one this binary understands — cleaner than silently mis-applying fields it doesn't know about. Lower versions are still readable.
