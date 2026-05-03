+++
title = "AI agents"
description = "How AI coding agents (Claude Code, Codex, Cursor, Gemini CLI, …) can use doma as a directory source."
weight = 4
+++

doma is a clean **path source** for the rest of your shell — and that includes AI coding agents. Instead of asking the user to re-state every project they want operated on, an agent that knows about doma can pull a precise list with one command.

For example: the user says *"update the Crystal version in CI for all my Crystal projects"*. Instead of guessing which directories qualify, the agent runs:

```bash
doma list -t crystal --paths
```

…and gets exactly the directories the user has already curated under that tag. Then it iterates with its own tools.

See [AI skill](./skill/) for the bundled `SKILL.md`, what it teaches the agent, and how to install it for Claude Code or other agents.
