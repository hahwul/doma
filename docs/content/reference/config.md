+++
title = "Configuration"
description = "Schema for ~/.config/doma/config.yml."
weight = 2
+++

doma reads `~/.config/doma/config.yml` (overridable via `DOMA_CONFIG`) on startup. The file is optional — every field has a default. Parsing is **strict**: unknown keys are an error, so a typo can't silently change behavior.

You can edit it by hand, or use [`doma config`](../commands/#config) to read and write keys from the CLI.

## Full schema

```yaml
# Where the SQLite database lives. Defaults to <home>/doma.db.
db_path: ~/.config/doma/doma.db

# Picker strategy.
# - auto    : interactive picker if STDIN is a TTY, else first-match.
# - builtin : force the picker (will block if no TTY available).
# - first   : always pick the first match (scriptable).
selector: auto

# Default behavior for tag derivation flags. CLI flags
# (--auto-tag / --no-auto-tag, --git-tag / --no-git-tag) override.
auto_tag:
  basename: false
  git: false
```

## Where doma writes

| Path | Override env | Notes |
|---|---|---|
| `~/.config/doma/` | `DOMA_HOME` | Parent dir for everything else. |
| `~/.config/doma/doma.db` | `DOMA_DB` | SQLite database (WAL files: `.db-shm`, `.db-wal`). |
| `~/.config/doma/config.yml` | `DOMA_CONFIG` | This file. |
| `~/.config/doma/.cd-hint-shown` | — | Sentinel. Tells `cd` not to print the wrapper-not-loaded hint twice. |

`~` is honored everywhere — both in the env vars and in any path you write into the config file.

## Migration

doma uses `PRAGMA user_version` to track the schema. Each release that needs new columns ships an additive migration; old databases upgrade transparently on first open. There's no manual migration step.

The current schema version is reported under **Database** in `doma doctor`.
