# Changelog

## Unreleased

### Added
- `export --portable` writes a snapshot meant for another machine: paths under the home directory become `~/…`, and each primary git checkout carries its `origin` URL as `remote` (embedded credentials stripped; worktrees and submodules get none). `import --clone` then registers the entries and `git clone`s the ones that aren't on disk — `--dry-run` previews, re-running skips what exists, a failed clone exits 1 but keeps the entry. No schema bump: older versions import portable snapshots and ignore `remote`
- Three more dynamic sets, usable anywhere a tag is (`list`, `run`, `status`, `-t` / `-x`, completion): `@ahead` (ahead of the upstream), `@behind` (behind the upstream as of the last fetch), and `@unreleased` (commits since the nearest tag; never-tagged repos are not members) — `doma run @ahead -- git push`, `doma status @unreleased`. `status` answers `@dirty` / `@ahead` / `@behind` from its own probe, and a git set now errors when `git` is missing instead of reading as empty

### Changed
- `list --pick` (and so `doma cd <tag>`) opens the same full-screen finder as `doma tui`, scoped to the matching directories, replacing the separate inline picker. Typing fuzzy-filters with highlights and the `tag:` / `-tag:` / `id:` / `path:` operators; `--query` stays a plain substring prefilter. `--builtin` now draws on `/dev/tty` even when stdin isn't a TTY, as documented
- `setup init` wrappers run `doma cd` through the same `DOMA_CD_FILE` hand-off as `tui`; `list --pick` writes its pick there when `DOMA_CD_FILE` is set. Re-run `doma setup install` or open a new shell to pick up the updated wrapper

## v0.5.0

doma leans into being a workbench for *sets* of directories: one selector across `list` / `run` / `status`, dynamic sets for the fix-and-retry loop, and a faster way onto the board.

### Added
- `run` exports `DOMA_PATH` / `DOMA_NAME` / `DOMA_ID` / `DOMA_TAGS` to every child, so per-directory commands need no `{}` templating or `sh -c` quoting (#53)
- `run` ends a multi-directory sweep with an `N ok · N failed · N skipped` tally on stderr that re-lists each failure; `--no-header` keeps it only when something failed, `-q` and `--json` drop it (#53)
- One tag selector for `list`, `run`, and `status`: repeat `-t` to AND, `-x/--exclude TAG` (repeatable, comma-split, glob ok) to subtract — `doma run crystal -x archived -- shards update` (#55)
- Dynamic sets usable anywhere a tag is (positional, `-t`, `-x`): `@failed` — the directories the last `doma run` didn't pass, including any `--fail-fast` never reached, so `doma run @failed -- make test` retries just those — and `@dirty` — git repos with uncommitted changes (#56)
- Shell completion for `@failed` / `@dirty` and `-x/--exclude` in bash, zsh, and fish (#57)
- `add --project-tag` / `--no-project-tag` (config `auto_tag.project`) tags by project type from marker files: `shard.yml` → `crystal`, `Cargo.toml` → `rust`, `go.mod` → `go`, `package.json` → `node`, `pyproject.toml` → `python`, and more (#58)
- `add -r PATH` registers every git repo at or under PATH — `doma add -r ~/Projects --project-tag` onboards a whole tree. Repos are leaves; non-repo hidden and dependency dirs are skipped; 4 levels deep; every root is scanned before anything is written (#58)
- `tags --all`. Plain `tags` / `tags --tree` now hide *name tags* — a tag on exactly one directory that equals its basename, what `--auto-tag` produces — and footer how many were hidden. `--names`, `-0`, `--json`, and `stats` still list every tag (#59)

### Changed
- `run a -t b` / `status a -t b` AND the two tags instead of erroring, and `-t a,b` on `run` / `status` splits on commas like `list -t` (#55)
- README and docs lead with `status` / `run` (#54)

### Fixed
- bash completion without bash-completion installed (stock macOS bash) rebuilds words from the command line, so `@failed` and `lang:crystal` aren't split at `@` / `:` and complete correctly; fish no longer offers tags after `--` or as a second positional (#57)

## v0.4.1

### Fixed
- `tui` Enter now reliably `cd`s through the shell wrapper. A full-screen finder must own the terminal, so the `setup init` wrappers no longer capture its stdout with `$(...)` (fragile under job control); they hand it a `DOMA_CD_FILE`, let it draw on the terminal, then `cd` to the path it writes there (the `lf`/`ranger` pattern). Re-run `doma setup install` or open a new shell to pick up the updated wrapper
- `tui` footer no longer promises `cd` when nothing will act on the selection: with the shell wrapper active Enter shows `cd`, otherwise it shows `print` and the help screen points at `doma setup install`

## v0.4.0

### Added
- `tui` — an interactive fuzzy finder over your registered directories (#39). Type to match paths; narrow with a query syntax (`tag:`, `-tag:`/`!tag:`, `id:`, `path:`, plus fuzzy terms). `Ctrl-A` registers a directory, `Ctrl-Y` copies the highlighted path, `F1`/`?` shows help. Enter prints the selection (same contract as `list --pick`) so `cd "$(doma tui)"` works
- Bare `doma` now launches the finder when stdin is a TTY, falling back to the help banner otherwise (`DOMA_NO_TUI=1` forces help); the `setup init` shell wrappers `cd` into its picked path too

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
