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
```

The output:

```json
{
  "version": 1,
  "generated_at": 1733000000,
  "entries": [
    { "path": "/Users/me/Projects/doma", "basename": "doma", "tags": ["crystal", "cli"] }
  ]
}
```

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

Import skips the "directory exists on disk" check (snapshots from machine A may reference paths machine B doesn't have). Missing paths are warned and skipped:

```
import: skipped /Users/alice/Projects/doma (not a directory)
```

## Use cases

### Backup before a risky operation

```bash
doma export --json -o ~/doma-backup-$(date +%F).json
```

### Version-control your tagging

Commit `~/doma.json` into a dotfiles repo. Re-apply on a fresh checkout:

```bash
doma import ~/doma.json --replace --yes
```

### Move to a new machine

Export on the old, scp to the new, import.

### Diff two snapshots

```bash
diff <(doma export --json) doma-yesterday.json
```

## Schema versioning

The `version` field protects forward-compat — doma refuses to import snapshots from a newer schema. Lower versions are still readable.
