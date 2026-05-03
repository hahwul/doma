+++
title = "AI agents"
description = "How AI coding agents (Claude Code, Codex, Cursor, Gemini CLI, …) can use doma as a directory source."
weight = 4
+++

doma is a clean **path source** for the rest of your shell — and that includes AI coding agents. Instead of asking the user to re-state every project they want operated on, an agent that knows about doma can pull a precise list with one command.

## What it looks like in practice

> **You:** Update the Crystal version to 1.20 in CI for all my Crystal projects.

The agent doesn't have to guess which repos qualify or scan the filesystem. It probes doma:

```bash
$ doma tags --names | grep -i crystal
crystal

$ doma list -t crystal --paths
/Users/me/Projects/doma
/Users/me/Projects/sandbox
/Users/me/Projects/cr-utils
```

…then iterates with its own `Read` / `Edit` / `Bash` tools across exactly the directories you've already curated under that tag. No "did you mean…?", no scanning `~/Projects` for `shard.yml`.

The same shape applies to *"run tests across my work projects"*, *"bump dependencies in everything I marked for review last week"*, *"open the most-recently used Crystal repo in my editor"*. Whatever shape your tags already have, that's the shape the agent operates in.

## Installing the skill

See [AI skill](./skill/) for the bundled `SKILL.md`, what it teaches the agent, and how to install it for Claude Code or other agents.
