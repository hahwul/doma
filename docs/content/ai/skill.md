+++
title = "AI skill"
description = "The bundled SKILL.md teaches a coding agent when to query doma and when to skip it."
weight = 1
+++

The repo ships [`skills/doma/SKILL.md`](https://github.com/hahwul/doma/blob/main/skills/doma/SKILL.md) — a portable agent skill file. It follows the Claude Code skill format, but it's just markdown with YAML frontmatter, so other coding agents (Codex, Gemini CLI, Cursor, Aider, …) can consume it directly or with light edits.

## What it teaches the agent

1. **Recognize category-style requests** ("my Crystal projects", "everything tagged X", "every repo I marked as Y") and reach for `doma list -t TAG --paths` before guessing.
2. **Pick the right output mode** — `--paths` for newline-separated, `-0` for NUL-safe pipelines, `--json` when it needs id/short_id/tags structurally.
3. **Compose with its own tools** — `doma cd` is useless inside an agent (no parent shell to mutate); use `doma list --pick` (one path) or `doma list --paths` (many) and pass the results to `Bash` / `Read` / `Edit` directly.
4. **Treat write ops as intent-driven** — `add` and `mark` only when the user clearly wants to track or bookmark a directory.
5. **Avoid bulk-destructive housekeeping** — `prune --gone`, `prune --expired`, and `import --replace` need explicit user authorization.

## Install

The recommended path is [Vercel Skills](https://github.com/vercel-labs/skills):

```bash
npx skills add hahwul/doma
```

That drops `SKILL.md` into your agent's skill directory. Restart your agent session to pick it up.

For a manual install (no node toolchain, or you want a working-tree symlink):

```bash
# copy into your agent's skill dir
cp -r skills/doma ~/.claude/skills/

# or symlink so updates land automatically
ln -s "$(pwd)/skills/doma" ~/.claude/skills/doma
```

The path above is for Claude Code. Substitute your agent's equivalent (e.g. `~/.codex/skills/`, project-local `.skills/`).

## Adapting for other agents

Most coding agents that support a "skills" or "rules" mechanism can consume the file directly or with light edits. The actionable content is the request-shape table near the bottom — port that into whatever your agent expects.
