# Changelog

## Unreleased

### Fixed
- Blank `DOMA_HOME` / `DOMA_CONFIG` env vars no longer resolve to the current directory — treated as unset (same guard `db_path` already had)
- `--git-tag` now detects the remote inside git worktrees and submodules (shared `config` resolved via `commondir`), instead of silently producing no host/repo tags
- `info` / `list` / `stats` no longer crash on out-of-range timestamps; relative times render `just now` instead of a negative `-Ns ago` for future timestamps (clock skew / cross-machine import)
- `trash restore --merge` keeps the live tag's TTL instead of overwriting it with a stale snapshot deadline (could silently expire a tag the user had made permanent)
- `prune --gone` deletes exactly the set it snapshots to the trash, so a path reappearing mid-sweep (e.g. a remounted disk) can no longer leave an un-restorable phantom trash entry

## v0.2.0

### Added
- `trash` command (`list`, `restore <short_id>`, `empty [--older DUR]`) with 7-day soft-delete recovery for `rm` and `prune --gone` (supports `--json`, `--merge` on restore)
- `list --by tag` groups output under per-tag headers (works with `--json`, `--paths`, `-0`)
- `--json` output for `add`, `trash list/add/empty` plus `short_id` in `add` result (agent/script friendly)
- `info` accepts short_id (full or prefix); surfaces trash status when relevant
- `list --check`, `--include-expired`, `--pick [--first | --builtin --query Q]`

### Changed
- `rm` snapshots to trash by default (`--hard` for permanent delete)
- Shell completion for bash/zsh/fish driven from a single `COMMAND_SPEC` table
- Numerous internal refactors (TTL SQL centralization, `TimeFormatter`, `TagRenderer`, `ShortIdResolver`, trash helpers, SQL utils)

### Fixed
- Trash restore races, `File.delete` races, existence checks inside transactions, concurrency lock
- Installer robustness (eval-line detection, comment skipping)
- Config blank `db_path` handling, humanized YAML parse errors
- Picker ANSI sanitization, suggester Levenshtein tie-breaking
- `rm -t TAG` now exits non-zero when no registered path matches
- Multiple early trash scaffolding and restore safety fixes

## v0.1.1

### Added
- `mark` and `run` accept `-t/--tag` as an alias for positional tag args; both forms can be mixed on `mark` (#7)
- Installation docs cover AUR and Snap install paths (#6)

### Changed
- Snap build downloads the prebuilt static binary instead of compiling Crystal in-tree; amd64 + arm64 matrix (#6)

### Fixed
- `list -t ''` (and whitespace/comma-only variants) silently matched every path; now rejected (#8)
- `run -t TAG cmd…` without `--` reported "tag specified both positionally and via -t"; now reports "command is required after '--'" (#8)
- `mark` no-tag hint advertises both positional and `-t TAG` forms (#8)
- Homebrew release workflow: skip checksum upload to source release (b2895f6)

## v0.1.0

- First version!
