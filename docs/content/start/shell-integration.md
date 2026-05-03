+++
title = "Shell integration"
description = "Make doma cd actually change your shell's working directory."
weight = 3
+++

`doma cd` is a small shell function, not a binary subcommand — a child process can't change its parent shell's cwd. The function takes a tag, calls `doma list -t <tag> --pick` to resolve it to one path, then runs `cd` for you.

## One-shot install

```bash
doma setup install
```

Detects your shell from `$SHELL` and appends an `eval` line (between marker comments) to `~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`. Idempotent.

Restart your shell or source the rc file, then:

```bash
doma cd crystal
```

## Manual install

`setup init` prints the wrapper to stdout:

```bash
# Bash / Zsh
eval "$(doma setup init zsh)"

# Fish
doma setup init fish | source
```

## Without the wrapper

For scripts and one-offs, use `list --pick` inline:

```bash
cd "$(doma list -t crystal --pick)"
```

`--pick` prints exactly one path: the only match if there's one, an interactive picker if you're on a TTY, or the most-recent match (with a stderr advisory) if you're piping.

## Uninstalling

The wrapper block is bracketed by sentinel comments:

```
# >>> doma shell integration >>>
…
# <<< doma shell integration <<<
```

Delete those lines and restart your shell.
