+++
title = "Comparison"
description = "How doma differs from multi-repo tools (mani, gita, myrepos) and from directory jumpers (zoxide, autojump, fzf)."
weight = 5
+++

doma is a workbench for sets of project directories, so its real neighbors are the multi-repo tools: [mani](https://github.com/alajmo/mani), [gita](https://github.com/nosarthur/gita), and [myrepos](https://myrepos.branchable.com/). It also gets compared to directory jumpers like zoxide because it can `cd`; that comparison is further down.

Short version: the multi-repo tools start from a list of repositories you maintain. doma starts from labels you attach as you go, and lets you select by what is true *right now* — which repos are dirty, which failed the last run.

## vs mani / gita / myrepos

Based on each project's own documentation at the time of writing.

| | doma | mani | gita | myrepos (`mr`) |
|---|---|---|---|---|
| Registering | CLI (`add`, `add -r`); no file to edit | `mani.yaml` you edit (`mani init` discovers repos) | CLI (`gita add`) | `.mrconfig` you edit, or `mr register` |
| Grouping | tags; `-t` repeats to AND, `-x` excludes, globs | tags; boolean `--tags-expr` (and / or / not) | groups, context | by directory and config file; no tags |
| Select by live state | yes — dynamic sets (`@dirty`, `@failed`, `@ahead`, `@behind`, `@unreleased`) | no | no (state is shown, not selectable) | a per-repo `skip` hook; a retry queue for commands that failed offline |
| Run a command across the set | `run`, `--parallel --jobs N` | `exec`, `--parallel --forks N` | `shell`, `super` | `mr run`, `-j N` |
| Named, reusable tasks | no, by design | yes (`tasks:`) | yes (`cmds.json`) | yes (custom commands in config) |
| Status dashboard | `status` | no dedicated command (`exec … git status` as a table) | `gita ll` | `mr status` |
| Machine-readable results | `--json` on `list`, `tags`, `info`, `stats`, `status`, `run` | table / markdown / html | not documented | not documented |
| Recreate the set on a new machine | `export --portable` + `import --clone` | `mani sync` | `gita freeze` + `gita clone -f` | `mr checkout`, `mr bootstrap` |
| Directories that aren't git repos | yes | yes (path-only projects) | git only | other VCSs (svn, hg, …) |
| Expiring labels | TTL tags, `mark` | no | no | no |
| Interactive UI | finder for jumping / picking | `mani tui` | no | no |
| Runtime | single static binary | single binary | Python 3 | Perl script |

### Where the others are stronger

- **Shared, declarative config.** `mani.yaml` and `.mrconfig` are files you edit, commit, and hand to a team; the file *is* the workspace. doma's state is a local SQLite database — personal by construction. It can rebuild a set elsewhere (`export --portable`, then `import --clone`), but that snapshot is an export you regenerate, not a source of truth you maintain.
- **Named tasks.** All three let you define a command once and call it by name. doma deliberately doesn't; `run` takes the command on the command line, and anything reusable belongs in your shell, a `justfile`, or a `Makefile`.
- **Tag expressions.** mani has boolean expressions over tags. doma has AND (`-t` repeated), NOT (`-x`), and globs, but no general OR.
- **Other version control systems.** myrepos drives svn, mercurial, and more. doma's `status` and its git-derived sets only understand git (its `run` works on any directory).

### Where doma is different

- **No file to maintain.** A directory joins a set the moment you `doma add . -t work`. There is no manifest to open, and `add -r ~/Projects --project-tag` labels a whole tree by project type.
- **Selecting by state, not just by name.** `doma run @failed -- make test` retries only what the last sweep failed on; `doma run work -t @dirty -- git stash` acts on only the repos with uncommitted changes. The other tools show state in their dashboards but can't select on it.
- **Built to be scripted.** `list`, `tags`, `info`, `stats`, `status`, and `run` all have `--json`, failures have [distinct exit codes](../../reference/commands/#exit-codes), and destructive commands refuse to run unattended without consent. That's also what makes doma usable from an [AI coding agent](../../ai/).
- **Labels that expire.** `doma mark spike` tags the current directory for a week; `--ttl` sets any lifetime. Useful for "the three repos I'm touching for this migration".
- **Not only repositories.** Any directory can be labeled, swept with `run`, and jumped to.

### Which one

- **mani** — a team shares one workspace definition, new machines should clone everything from it, and you want named tasks.
- **gita** — the work is git-centric and you mostly want to delegate git subcommands to groups of repos.
- **myrepos** — a long-lived `~/.mrconfig`, several version control systems, per-repo custom commands.
- **doma** — the set is personal and changes often, you want to act on "whatever is dirty / failed / tagged X right now", or a script or agent needs structured results.

They aren't mutually exclusive: a `mani.yaml` can own what gets cloned while doma labels and sweeps what's on disk.

## vs zoxide / autojump / z / fasd

These are *jumpers*. They watch `cd` and rank directories by how often and how recently you visit them, then `z foo` jumps to the best match.

doma is not competing here. It never adds a directory on its own, and recall is by label rather than by inferred frecency. `doma cd <tag>` and the bare-`doma` finder exist because once directories are labeled, jumping to one is nearly free — not because doma is trying to out-guess zoxide.

**Use zoxide when** you want zero-friction recall and don't care about labels.
**Use doma when** you want explicit categories, or need to operate on every directory in a category at once.

They compose fine: `z` for casual jumping, `doma` for the labeled sets. fasd adds recent *files* on top of the same model; that side is out of doma's scope.

## vs fzf

fzf is a fuzzy finder — a generic pipe consumer that stores nothing. doma is an upstream of it: it remembers paths and labels, and you can pipe them into fzf if you prefer it to doma's own finder.

```bash
cd "$(doma list --paths | fzf)"   # fzf over doma-tracked directories
doma cd                           # or doma's built-in finder
```

## When you don't need doma

If the set of directories you work in is small enough to type by hand, or your editor's project switcher covers it, doma is overkill. The value compounds when:

- You have 10+ directories you actually return to.
- You operate on them in *categories* (`run shards build across all my Crystal projects`).
- You want bookmarks that auto-expire (`mark spike` for the week).
- You want an AI coding agent to know which directories qualify for a category-spanning task ([AI agents](../../ai/)).
