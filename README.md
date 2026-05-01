<div align="center">
  <img alt="doma Logo" src="" width="500px;">
  <p>Directory tag manager — put your directories on the cutting board.</p>
</div>

<p align="center">
<a href="https://github.com/hahwul/doma/blob/main/CONTRIBUTING.md">
<img src="https://img.shields.io/badge/CONTRIBUTIONS-WELCOME-000000?style=for-the-badge&labelColor=black"></a>
<a href="https://github.com/hahwul/doma/releases">
<img src="https://img.shields.io/github/v/release/hahwul/doma?style=for-the-badge&color=black&labelColor=black&logo=web"></a>
<a href="https://crystal-lang.org">
<img src="https://img.shields.io/badge/Crystal-000000?style=for-the-badge&logo=crystal&logoColor=white"></a>
</p>

<p align="center">
  <a href="#installation">Installation</a> •
  <a href="#shell-integration">Shell integration</a> •
  <a href="#pipelines">Pipelines</a> •
  <a href="#ai-agents">AI agents</a> •
  <a href="#contributing">Contributing</a> •
  <a href="https://github.com/hahwul/doma/releases">Releases</a>
</p>

---

doma is a Crystal CLI for tagging directories so you can recall, browse, or batch-execute across them. Tag your projects once (`crystal`, `work/proj-a`, `bookmark`), then jump to them, list them, or run a command across the whole set without re-typing paths.

```bash
doma add ~/Projects/my-app -t crystal -t web
doma list -t crystal --paths | xargs -I{} sh -c 'cd {} && shards build'
doma cd crystal                # interactive picker, then cd  (needs `doma setup install`)
doma mark spike                # bookmark cwd for 7 days
```

<details>
<summary><strong>Features</strong></summary>

### Tagging
- Multiple tags per directory; tags are reusable across paths
- Auto-tag from basename and Git remote (`--auto-tag`, `--git-tag`)
- Glob filter on tags (`list -t 'work/*'`, `run 'work/*' -- cmd`) — shell-style: `*` matches within one segment, `**` crosses `/`, `?` is a single non-`/` character
- Hierarchical tag display (`tags --tree`)
- TTL on tags: `--ttl 30m | 1h | 7d | 2w`, `--tmp` for the 7-day default, `mark` for the cwd + 7-day shortcut
- Stable 7-char `short_id` per directory — survives renames; usable via `rm <id>` and `trash restore <id>`

### Navigation & operations
- `list --pick` resolves to a single path (Crystal-native picker, no fzf dependency); the `doma cd <tag>` shell wrapper from `doma setup install` builds on it
- `run <tag> -- <cmd>` to execute a command in every tagged directory; `--parallel` (with `--jobs N`, default CPU count) and `--fail-fast` available
- `move` to follow a path that moved on disk; tags carry over
- `rename` to merge or relabel tags
- Recency tracking — most-used directories surface first in pickers and `list --by recent`
- Substring search across path / basename / tag (`doma list <query>`)
- Single-entry detail view (`doma info` defaults to cwd) — tags, TTLs, last-used, exists check
- Dead-path detection: `list --check`, `prune --gone`; expiry purge: `prune --expired`

### Pipelines & scripting
- `list -t TAG --paths` — newline-separated paths for `while read` / `xargs`
- `list -t TAG -0` — NUL-separated for `xargs -0`, safe for paths with spaces
- `list --json`, `tags --json`, `stats --json`, `export --json|--yaml`
- "Did you mean ..." hints (Levenshtein) for typos
- Output stays color-free when piped; SIGPIPE-safe

### Storage & safety
- SQLite-backed (WAL, foreign keys, busy_timeout) — handles concurrent doma calls across multiple shells
- Path canonicalization: `~`, symlinks, and trailing slashes all collapse to one stable key
- Transactional writes; atomic snapshot import/export
- Schema migrations via `PRAGMA user_version` — old DBs upgrade transparently
- Strict tag validation; sanitized auto-tags so a `.dotfiles` repo doesn't break `--auto-tag`

### Distribution & integration
- Single static binary (musl + sqlite-static); no runtime dependencies
- Packaged for Homebrew, AUR, Snap, .deb, .rpm, .apk
- Multi-arch container image at `ghcr.io/hahwul/doma`
- CycloneDX SBOM published with every release
- Shell integration installer (`doma setup install`) for bash, zsh, fish
- AI skill for Claude / Cursor / etc. — see [skills/doma/SKILL.md](skills/doma/SKILL.md)

</details>

## Installation

### Homebrew

```bash
brew tap hahwul/doma
brew install doma
```

### From source

```bash
git clone https://github.com/hahwul/doma.git
cd doma
shards install
shards build --release --no-debug --production
```

### Pre-built binaries

Static Linux and macOS binaries are attached to every [release](https://github.com/hahwul/doma/releases). `.deb` / `.rpm` / `.apk` / `.snap` packages are published alongside.

### Container

```bash
docker pull ghcr.io/hahwul/doma:latest
docker run --rm -it -v "$HOME/.config/doma:/root/.config/doma" \
  ghcr.io/hahwul/doma list
```

## Shell integration

`doma cd` lives in a shell function rather than the binary — a child process can't change its parent shell's working directory. The function calls `doma list -t <tag> --pick` (the binary's single-pick primitive) and runs `cd` on the result. One-shot install:

```bash
doma setup install                    # auto-detects $SHELL, appends to your rc
exec $SHELL                           # or `source ~/.zshrc`
doma cd crystal                       # interactive picker, then cd
```

If you'd rather wire it manually:

```bash
eval "$(doma setup init zsh)"         # bash / zsh
doma setup init fish | source         # fish
```

Without the wrapper, the equivalent inline form works everywhere:

```bash
cd "$(doma list -t crystal --pick)"
```

## Pipelines

doma is designed to compose with the rest of your shell. A few common shapes:

```bash
# Update CI files across every Crystal project
doma list -t crystal --paths | while read -r d; do
  (cd "$d" && sed -i 's/crystal: 1.20/crystal: 1.21/' .github/workflows/*.yml)
done

# Status across work repos (paths-with-spaces safe)
doma list -t 'work/*' -0 | xargs -0 -I{} sh -c 'cd "{}" && git status -s | head'

# Structured access via jq
doma list --json | jq -r '.[] | "\(.short_id)\t\(.path)\t\(.tags|join(","))"'

# Ad-hoc bookmarks during a code review session
doma mark auth-review
# ... cd around ...
doma list -t auth-review --paths
```

## AI agents

doma ships a [Claude Code skill](skills/doma/SKILL.md) that teaches an agent when to query the database for a path list ("update CI for all my Crystal projects") and when to register or bookmark a directory ("track this", "remember this for later").

Install via [Vercel Skills](https://github.com/vercel-labs/skills):

```bash
npx skills add hahwul/doma
```

Or copy the file by hand into your agent's skill directory:

```bash
cp -r skills/doma ~/.claude/skills/
# or symlink so updates land automatically:
ln -s "$(pwd)/skills/doma" ~/.claude/skills/doma
```

## Contributing

doma is open-source and PRs are welcome. Please check [CONTRIBUTING.md](CONTRIBUTING.md) before sending a patch.

## Why "doma"?

Doma (도마) is the Korean word for **cutting board** — the workbench where ingredients are gathered, grouped, and chopped before going into the pan. doma aims to be the same kind of workbench for your directories: pull the ones you care about onto a single board, group them by category (`crystal`, `work/proj-a`, `bookmark`), and run bulk operations across the piles as if they were mise en place.
