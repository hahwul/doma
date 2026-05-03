+++
title = "Troubleshooting"
description = "Common errors, diagnostic flow, and recovery paths."
weight = 4
+++

When something looks off, start here:

```bash
doma doctor
```

`doctor` reports paths, config status, and database stats — most issues show up in its output before they show up as a confusing error.

## `doma cd` does nothing / "command not found"

The wrapper isn't loaded. doma's `cd` lives in a shell function (a child process can't change its parent shell's cwd), and it has to be sourced into your interactive shell.

```bash
doma setup install     # auto-append the wrapper to your rc file
exec $SHELL            # reload (or restart the terminal)
```

To verify, run `type doma` — you should see it as a function in zsh/bash, or `doma is a function` in fish. If it still shows as a binary, the rc file change didn't take effect; check `~/.zshrc` / `~/.bashrc` for the `# >>> doma shell integration >>>` block.

## "DOMA_HOME points at a file" / similar config errors

Exit code 5 means doma's environment is misconfigured. The error message names exactly which variable and why:

```
✗ DOMA_HOME points at a file, not a directory: /etc/passwd
```

Unset the bad value (`unset DOMA_HOME`) or fix the path. doma's defaults under `~/.config/doma/` are usually what you want.

## `doma list` shows nothing after a path moved

Two cases:

1. **Path moved on disk, doma doesn't know yet.** Update with `doma move /old /new` — tags carry over.
2. **Path is gone for real.** `doma list --check` annotates dead paths with `[gone]`. Sweep with `doma prune --gone` (snapshotted to trash for 7 days; recoverable via `doma trash list` / `doma trash restore <id>`).

If an external disk is *temporarily* unmounted, prefer leaving the entries alone — `prune --gone` would mark them all as missing. They reappear automatically once the disk is back.

## "schema mismatch" or "version is higher than I understand" on import

You're importing a snapshot from a newer doma than you're running. Upgrade doma (`brew upgrade doma`, or fetch the latest release) and retry. Lower-version snapshots are always readable; only newer ones are refused.

## I deleted something I shouldn't have

```bash
doma trash list                  # what's recoverable
doma trash restore <short_id>    # bring it back
```

Anything from `doma rm <path>` or `doma prune --gone` (without `--hard`) is recoverable for 7 days. After that the next trash op auto-prunes it.

If you used `--hard`, the snapshot wasn't written and recovery isn't possible — restore from your most recent `doma export` instead.

## A tag I expected isn't matching

Common causes:

- **TTL elapsed.** Expired tags are hidden from `list` by default. Check with `doma list --include-expired`.
- **Glob vs exact match.** `-t work/auth` is an exact match; `-t 'work/*'` is a glob. `*` matches within one segment, `**` crosses `/`, `?` is a single non-`/` character.
- **Typo / case.** Tag matching is case-sensitive. `doma tags --names | grep -i ...` to confirm what's actually stored.

## Picker doesn't open in a script

`--pick` falls back to "first match" when stdin isn't a TTY (with a stderr advisory). For scripts you usually want this — pass `--first` explicitly to silence the advisory. To force the picker on anyway (e.g. through a terminal multiplexer), use `--builtin`.

## Auto-tag silently skipped

`--auto-tag` tries to use the directory's basename. If the basename can't form a valid tag even after sanitization (e.g. `...`), doma skips it rather than erroring. Same for `--git-tag` when there's no `[remote "origin"]` in `.git/config`.

If you wanted that tag, add it explicitly with `-t TAG`.

## Database locked / "another doma is running"

doma uses SQLite WAL with `busy_timeout`, so concurrent reads from multiple shells work fine. A persistent lock usually means a previous process crashed mid-write. Check for stale `*.db-shm` / `*.db-wal` files next to `doma.db`, and if no doma is actually running, removing them is safe — SQLite will recreate on next open.

## Reporting a bug

Include the output of `doma doctor` and `doma version` in the issue. Those answer 80% of "what does your environment look like?" questions before we have to ask.

If the problem is reproducible from a fresh DB, even better — point `DOMA_DB` at a scratch location and reproduce there:

```bash
DOMA_DB=/tmp/doma-repro.db doma add /some/path -t test
DOMA_DB=/tmp/doma-repro.db doma list
```
