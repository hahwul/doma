+++
title = "Claude Code skill"
description = "The bundled SKILL.md teaches an agent when to query doma and when to skip it."
weight = 1
+++

The repo ships [`skills/doma/SKILL.md`](https://github.com/hahwul/doma/blob/main/skills/doma/SKILL.md) — a Claude Code skill file. Drop it into your agent's skill directory (or copy its triggers/rules into your own system) and the agent will:

1. **Recognize category-style requests** ("my Crystal projects", "all the directories tagged X", "every repo I marked as Y") and reach for `doma list -t TAG --paths` before guessing.
2. **Pick the right output mode** — `--paths` for newline-separated, `-0` for NUL-safe pipelines, `--json` when it needs id/short_id/tags structurally.
3. **Compose with its own tools** — the skill is explicit that `doma cd` is useless inside an agent (no parent shell to mutate); the agent should capture paths from `list` and pass them to `Bash` / `Read` / `Edit` directly.
4. **Treat write ops as intent-driven** — `add` and `mark` are encouraged when the user clearly wants to track or bookmark a directory, but the skill warns against running them as a side effect of unrelated work.
5. **Avoid bulk-destructive housekeeping** — `rm --gone`, `rm --expired`, and `import --replace` are flagged as needing explicit user authorization.

## Installing the skill

The recommended path is [Vercel Skills](https://github.com/vercel-labs/skills), which fetches the file straight from this repo:

```bash
npx skills add hahwul/doma
```

That drops `SKILL.md` into your agent's skill directory and you're done — restart your agent session to pick it up.

If you prefer a manual install (no node toolchain, or you want a working-tree symlink so edits land live), copy the file by hand:

```bash
# from inside doma's checkout, copy to your agent's skill dir:
cp -r skills/doma ~/.claude/skills/

# or symlink so updates land automatically:
ln -s "$(pwd)/skills/doma" ~/.claude/skills/doma
```

Either way, the agent will load the skill on next session start.

## What the skill does *not* do

It doesn't run doma itself — it teaches the agent when to. The agent still uses its standard tool-call mechanism (e.g. `Bash` for shell-outs); the skill just gives it the trigger conditions, the right flags for each shape of request, and the guardrails for write operations.

## Adapting for non-Claude agents

The format is markdown with YAML frontmatter; most coding agents that support a "skills" or "rules" mechanism can consume it directly or with light edits. The actionable content is in the request-shape table near the bottom — port that into whatever your agent's instruction system expects.
