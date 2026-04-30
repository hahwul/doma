# Changelog

## Unreleased

### Breaking
- The `cd` subcommand has been removed from the binary. Single-path
  resolution moved into `doma list --pick` so the binary stays purely
  set-oriented; the user-facing `doma cd <tag>` command is now provided
  by the shell function shipped via `doma setup install` (re-run that
  command to refresh the wrapper). Scripts that called the bare
  binary with `cd` (without the wrapper) need to switch to:
  `cd "$(doma list -t <tag> --pick)"`.
- `doma cd <short_id>` and `doma cd <short_id_prefix>` are no longer
  supported. short_ids remain valid for `rm <id>` and
  `trash restore <id>`. `--index N` is gone with no replacement —
  `--pick` opens an interactive picker on a TTY, or `--first` (and
  `--by recent`) for deterministic non-interactive selection.
- `doma rm --gone` and `doma rm --expired` have moved to the new
  top-level `doma prune` command (`doma prune --gone`,
  `doma prune --expired`). Splitting bulk cleanup out of the
  per-path `rm` makes both forms self-announcing: `rm` is now strictly
  single-target, `prune` is strictly bulk.
- `doma setup doctor` has moved to the top level as `doma doctor`. The
  diagnostic isn't shell-integration-specific and now sits with other
  top-level operational commands. The old path still exits cleanly
  with a redirect to the new location.

### Added
- `doma list --pick` resolves the filtered set down to a single path
  on stdout (interactive picker on TTY, deterministic first-pick with
  stderr advisory off-TTY). Composable flags: `--query Q`, `--first`,
  `--builtin`. Honors the user's `selector` config setting.
- `doma info [<path>]` — single-entry detail view. Defaults to cwd,
  so the typical "did I tag this directory? with what?" question is
  one keystroke. Shows short_id, tags + TTL remaining, created_at,
  last_used_at, and an exists check. `--json` mirrors the schema.
- `doma prune` — bulk cleanup for missing paths (`--gone`) and
  expired tag rows (`--expired`).
- `doma doctor` — top-level install/state diagnostic (was
  `doma setup doctor`).
- `doma setup install` now also honors the global `-y` / `--yes` flag,
  matching every other interactive command.

## v0.1.0

- Init
