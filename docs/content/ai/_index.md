+++
title = "AI agents"
description = "How AI coding agents (Claude Code, Cursor, etc.) can use doma as a directory source."
weight = 4
+++

doma is designed to be a clean **path source** for the rest of your shell — and that includes AI agents. Instead of asking the user to re-state every project they want operated on, an agent that knows about doma can pull a precise list with one command.

The example use case: the user says *"update the Crystal version in CI for all my Crystal projects"*. Instead of guessing which directories qualify, the agent runs:

```bash
doma list -t crystal --paths
```

…and gets exactly the directories the user has already curated under that label. Then it iterates with its own tools.

## Quick install

```bash
npx skills add hahwul/doma
```

That pulls the [bundled `SKILL.md`](https://github.com/hahwul/doma/blob/main/skills/doma/SKILL.md) into your agent's skill directory via [Vercel Skills](https://github.com/vercel-labs/skills). Restart your agent session and it's available.

## Pages here

- [AI skill](./skill/) — the bundled `SKILL.md` and what it teaches a coding agent about when (and when not) to invoke doma.
