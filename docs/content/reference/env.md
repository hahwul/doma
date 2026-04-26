+++
title = "Environment"
description = "Environment variables doma honors."
weight = 3
+++

| Variable | Purpose | Default |
|---|---|---|
| `DOMA_HOME` | doma's config + state directory. | `~/.config/doma` |
| `DOMA_DB` | Path to the SQLite database. | `<DOMA_HOME>/doma.db` |
| `DOMA_CONFIG` | Path to `config.yml`. | `<DOMA_HOME>/config.yml` |
| `NO_COLOR` | If set (any value), disables ANSI colors. Honored by default; `--color` overrides. | unset |
| `COLUMNS` | Terminal width hint. Used by the picker for layout. | autodetected |
| `SHELL` | Read by `setup install` to pick the right rc file. | from process env |

Each path-shaped variable is `~`-expanded before use. Pre-existing tilde is fine:

```bash
DOMA_HOME=~/scratch-doma doma list   # works as expected
```

## Misconfiguration → friendly errors

Pointing an env var at the wrong kind of thing surfaces as a clean `ConfigError`, not an internal trace:

```
$ DOMA_HOME=/etc/passwd doma list
✗ DOMA_HOME points at a file, not a directory: /etc/passwd
```

```
$ DOMA_DB=/var doma list
✗ DOMA_DB points at a directory, not a file: /var
```

Both exit 5 (the ConfigError exit code) so scripts can branch on it.
