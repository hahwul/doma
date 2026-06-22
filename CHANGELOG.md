# Changelog

## Unreleased

### Added
- `tui` — an interactive fuzzy finder over your registered directories, built on [termisu](https://github.com/omarluq/termisu) (compiled in; no extra runtime dependency). Type to fuzzy-match paths with match highlighting; narrow with a small query syntax — `tag:NAME` (glob-aware, repeatable AND), `-tag:`/`!tag:` to exclude, `id:PREFIX`, `path:TERM`, plus bare fuzzy terms. Navigate with arrows / `Ctrl-N`·`Ctrl-P` / PageUp·PageDown. `Ctrl-A` registers a directory and `Ctrl-Y` copies the highlighted path (OSC-52), both without leaving the finder; `F1`/`?` shows help. Enter prints the selected path to stdout and bumps recency so the shell wrapper `cd`s into it — same contract as `list --pick`; Esc/`Ctrl-C` cancels (exit 130). The UI lives on `/dev/tty`, so `cd "$(doma tui)"` works
- Running `doma` with no subcommand now launches the finder when stdin is a TTY, falling back to the help banner otherwise (`DOMA_NO_TUI=1` forces help). The `doma setup init` shell wrappers `cd` into the path picked by bare `doma` / `doma tui` as well as `doma cd`

## v0.3.0

### Added
- `status [<tag>]` — git dashboard across a tagged set: branch, ahead/behind vs upstream, and a dirty-file count, one row per directory. `--dirty` filters to repos with uncommitted work; `--json` emits the full per-entry breakdown; `--jobs N` tunes the parallel probe (default CPU count). Non-git and missing paths surface as `not a git repo` / `gone`. Shells out to `git`; errors clearly if git isn't on PATH

### Fixed
- Harden IO and terminal boundaries so bad input degrades gracefully instead of crashing or hanging (c311bf4):
  - `add` with `auto_tag.git` no longer crashes on an unreadable `.git` file, config, or commondir — git detection returns empty instead of raising
  - `doctor` survives a malformed `config.yml`, reporting the error instead of dying before any section prints
  - `run --parallel`: an unexpected worker failure degrades to a failed directory (exit 126) rather than deadlocking the reaper
  - `picker`: swallows invalid UTF-8 input, treats a TTY hangup as cancel, and always restores terminal state
  - `config get`/`set`/`list`/`unset`: non-string YAML keys (e.g. `1: foo`) raise a clear `ConfigError` instead of crashing
  - permission / not-a-file IO errors surface as `ConfigError`/`ImportError`/`Error` instead of leaking as `internal error`
  - a failed `~` expansion (no `$HOME`, no passwd entry) raises a `ValidationError` with a hint
  - broken-pipe (`EPIPE`) detection also checks the OS error code

## v0.2.1

### Changed
- Homebrew installs a prebuilt binary via tap instead of building from source; macOS x86_64 added (#36)
- Internal refactor: split `Database` by concern, extract `ListCommand` output modes (no behavior change) (#26)

### Fixed
- Blank `DOMA_HOME` / `DOMA_CONFIG` env vars treated as unset (#25)
- `--git-tag` detects the remote inside git worktrees and submodules (#25)
- `info` / `list` / `stats` no longer crash on out-of-range timestamps; future times render `just now` (#25)
- `trash restore --merge` keeps the live tag's TTL instead of a stale snapshot deadline (#25)
- `prune --gone` trashes exactly the snapshotted set, avoiding phantom trash entries on mid-sweep changes (#25)
- `tags` / `stats` no longer count expired tag associations; dropped a double space before `(expires …)` (#27)
- `import --merge` reports `N imported (X new, Y existing), Z skipped` (#28)
- Unknown flags / missing option values use doma's voice with a `--help` pointer (#29)
- `move` shows the canonical stored path instead of the raw argument (#30)
- `run <tag> <cmd>` without `--` explains the missing separator and suggests the fixed form (#31)
- `list --json --paths` and `tags --tree --json/--names` reject conflicting output formats (#32)
- Edge cases: `export --json --yaml` rejected, `tags` rejects empty path segments, commands survive a deleted cwd, `run` on a gone dir points at `prune --gone` (#33)
- `info <short_id>` checks the trash; `-t ','` errors `tag is empty` in `add` / `rm` / `mark` (#34)

## v0.2.0

### Added
- `trash` command (`list`, `restore <short_id>`, `empty [--older DUR]`) with 7-day soft-delete for `rm` and `prune --gone`
- `list --by tag` groups output under per-tag headers
- `--json` output for `add` and `trash`; `short_id` in `add` result
- `info` accepts short_id (full or prefix); surfaces trash status
- `list --check`, `--include-expired`, `--pick`

### Changed
- `rm` snapshots to trash by default (`--hard` for permanent delete)
- Shell completion driven from a single `COMMAND_SPEC` table
- Internal refactors (TTL SQL, `TimeFormatter`, `TagRenderer`, `ShortIdResolver`, trash/SQL helpers)

### Fixed
- Trash/`File.delete` races, in-transaction existence checks, concurrency lock
- Installer robustness, blank `db_path`, humanized YAML errors
- Picker ANSI sanitization, suggester tie-breaking
- `rm -t TAG` exits non-zero when no path matches

## v0.1.1

### Added
- `mark` and `run` accept `-t/--tag`; both forms can be mixed on `mark` (#7)
- Install docs cover AUR and Snap (#6)

### Changed
- Snap build downloads the prebuilt static binary; amd64 + arm64 (#6)

### Fixed
- `list -t ''` (and whitespace/comma-only) now rejected instead of matching every path (#8)
- `run -t TAG cmd…` without `--` reports the right error (#8)
- `mark` no-tag hint shows both positional and `-t TAG` forms (#8)
- Homebrew workflow: skip checksum upload to source release (b2895f6)

## v0.1.0

- First version!
