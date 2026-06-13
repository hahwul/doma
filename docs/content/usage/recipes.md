+++
title = "Recipes"
description = "Real-world workflows that combine doma with the rest of your toolkit."
weight = 9
+++

Concrete patterns. Pick what fits, ignore the rest.

## Monday morning: pull every active project

```bash
doma run work -- git -C . fetch --all --prune
doma run work --parallel -- git pull --ff-only
```

Sequential fetch (a quick cache warm) followed by parallel `pull --ff-only`. If anything has unmerged work or upstream divergence, it surfaces in the per-directory exit summary at the end.

For a tighter loop with custom logic:

```bash
doma list -t work --paths | while read -r d; do
  cd "$d" || continue
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || continue
  [ "$branch" = "main" ] && git pull --ff-only
done
```

## Bookmark a PR's checkout for the review window

```bash
gh pr checkout 1234
doma mark review-1234              # cwd, 7-day TTL
# … review, comment, push fixes …
doma rm . -t review-1234           # done; entry stays if you have other tags
```

If reviews routinely run longer than a week, use `doma add . -t review-1234 --ttl 30d` instead. Re-running the same `add` resets the clock.

## "What did I tag for the spike last week?"

```bash
doma list -t spike --include-expired --by recent
```

Expired-but-not-pruned tags survive until the next `prune --expired` (or until you re-tag, which clears `expires_at`). Useful for retrospectives.

## Periodic cleanup (cron / launchd / systemd timer)

A weekly sweep that snapshots first, then drops expired bindings and missing paths:

```bash
#!/usr/bin/env bash
set -euo pipefail

snap_dir="${HOME}/.doma-snapshots"
mkdir -p "$snap_dir"
doma export --json -o "${snap_dir}/$(date +%F).json"

doma prune --expired -y
doma prune --gone -y                # snapshotted to trash; recoverable for 7d
```

Run it with whatever scheduler you trust. The export gives you a rollback if a sweep nukes something you wanted.

## Project-bootstrap: tag on `cd`

If you want any directory you `cd` into and that contains `.doma-tags` to auto-register, add this to your shell rc *after* `doma setup install`:

```bash
chpwd_doma_autoadd() {
  local f="$PWD/.doma-tags"
  [ -f "$f" ] || return
  local tags
  tags=$(tr '\n' ',' < "$f" | sed 's/,$//')
  doma add . -t "$tags" >/dev/null 2>&1
}
# zsh:
autoload -U add-zsh-hook
add-zsh-hook chpwd chpwd_doma_autoadd
chpwd_doma_autoadd
```

Drop a `.doma-tags` file in any project (one tag per line) and the tags follow the repo around in version control.

## Snapshot to a dotfiles repo

Commit your tag set so a fresh machine setup is one command:

```bash
# in your dotfiles repo
doma export --json -o ./doma.json
git add doma.json && git commit -m "doma: refresh snapshot"

# on a new machine
doma import ./doma.json --replace --yes
```

Paths that don't exist on the new machine are warned and skipped. Re-run `doma list --check` after import to see what didn't survive.

## Pick a project to open in your editor

```bash
doma list -t crystal --pick --by recent | xargs -I{} code {}
```

`--pick` resolves to one path (interactive picker if more than one match), recency-first. Swap `code` for `cursor`, `subl`, `idea`, etc.

A nicer one-liner for zsh users:

```bash
function dcode() { code "$(doma list -t "${1:-}" --pick --by recent)" }
dcode crystal
```

## Cross-tag pipelines

"Every Crystal repo that I also marked as work":

```bash
doma list -t crystal --json \
  | jq -r '.[] | select(.tags | index("work")) | .path'
```

`-t TAG` is exact-match against one tag; for set intersection, fall back to `--json | jq`.

## Run only on dirs that still build

```bash
doma list -t crystal --paths | while read -r d; do
  cd "$d" || continue
  shards check >/dev/null 2>&1 || continue
  doma add . -t buildable --tmp     # 7d TTL bookmark
done
doma list -t buildable
```

A "compiles right now" view that auto-expires.

## Backup before a risky import

```bash
doma export --json -o ~/doma-pre-restore-$(date +%s).json
doma import some-snapshot.json --replace --yes
```

If `--replace` was the wrong call, `doma import ~/doma-pre-restore-*.json --replace --yes` puts you back.

## Find dead entries without committing to a sweep

```bash
doma list --check | grep '\[gone\]'
```

`prune --gone` is the destructive form; `--check` is the report. Use the report to decide whether the disk is just unmounted or the path is genuinely gone.
