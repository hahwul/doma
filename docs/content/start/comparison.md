+++
title = "Comparison"
description = "How doma differs from zoxide, autojump, z, fasd, and fzf."
weight = 5
+++

doma overlaps with several familiar tools. Short version: those tools *infer* where you've been; doma *asks you to label* what matters. They give heuristic recall; doma gives deterministic recall plus bulk operations.

## At a glance

| | doma | zoxide / z / autojump | fasd | fzf |
|---|---|---|---|---|
| Recall by | tag (deliberate) | frecency on `cd` history (inferred) | frecency on `cd` + file history | interactive fuzzy match against any list |
| Multi-directory ops (`run` across N dirs) | yes | no | no | no |
| Directory metadata (TTL, last-used, tags) | yes | last-used only | last-used only | n/a |
| Pipeline-friendly (`--paths`, `-0`, `--json`) | yes | partial | partial | yes (consumer) |
| Built-in picker | yes (Crystal-native) | no (delegates to fzf) | no | yes |
| Soft delete / recovery | yes (trash) | n/a | n/a | n/a |
| Database | SQLite | flat file | flat file | n/a |

## vs zoxide / autojump / z

These are *autojump* tools. They watch `cd` and rank directories by how often + how recently you visit them, then `z foo` jumps to the best match.

**Use zoxide when**: you want zero-friction recall and don't care about labels.
**Use doma when**: you want explicit categories (`crystal`, `work/proj-a`, `bookmark`), or you need to operate on *every* directory in a category at once.

They compose fine — `z` for casual jumping, `doma cd` when you want a specific lens. Some users keep both.

The picker model also differs: zoxide leans on `fzf` for interactive selection; doma ships its own picker so the binary works with no extra dependencies, but you can still pipe `doma list -t TAG --paths | fzf` if you prefer.

## vs fasd

fasd is autojump + recent-files in one tool. The directory side overlaps with zoxide; the file side is out of doma's scope. If you mostly use fasd's `z` and `f` commands, doma replaces `z` (with deliberate labels) and is orthogonal to `f`.

## vs fzf

fzf is a fuzzy finder — a generic pipe consumer. It doesn't store anything, it just matches against whatever list you feed it. doma is an upstream of fzf: it remembers paths, you can pipe its output to fzf if you want fuzzy filtering on top.

```bash
# pick a doma-tracked directory with fzf
cd "$(doma list --paths | fzf)"

# or use doma's built-in picker (no fzf needed)
doma cd
```

## vs `cdr` / shell history

zsh's `cdr` and similar shell built-ins recall recent directories. They share zoxide's "implicit history" model — useful, but doesn't survive across machines, doesn't carry tags, and can't operate across multiple directories at once.

doma's snapshots (`export` / `import`) are explicit and portable; tags travel with the entries.

## When you don't need doma

If your "directories I work in" set is small enough to type by hand, or your IDE's project picker covers it, doma is overkill. The value compounds when:

- You have 10+ directories you actually return to.
- You operate on them in *categories* (`run shards build across all my Crystal projects`).
- You want bookmarks that auto-expire (`mark spike` for the week).
- You want an AI coding agent to know which directories qualify for a category-spanning task ([AI agents](../../ai/)).
