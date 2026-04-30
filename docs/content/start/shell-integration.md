+++
title = "Shell integration"
description = "Make doma cd actually change your shell's working directory."
weight = 3
+++

`doma cd` lives in a small shell function, not in the binary itself — a child process can't change its parent shell's working directory (POSIX, not a doma limitation). The function takes a tag, calls `doma list -t <tag> --pick` to resolve it to a single path, then runs `builtin cd` for you. The same pattern zoxide, starship, and mise use.

## One-shot install

```bash
doma setup install
```

That detects your shell from `$SHELL`, finds the right rc file (`~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`), and appends a single `eval` line between marker comments. Idempotent — running it twice is a no-op.

Restart your shell or source the rc file, then:

```bash
doma cd crystal   # actually cd's
```

## Manual install

If you'd rather wire it yourself, `setup init` prints the wrapper to stdout:

```bash
# Bash / Zsh — add to ~/.bashrc or ~/.zshrc
eval "$(doma setup init zsh)"

# Fish — add to ~/.config/fish/config.fish
doma setup init fish | source
```

## Without the wrapper

The binary itself doesn't ship a `cd` subcommand — calling `doma cd` directly errors and points you here. For scripts and one-offs that don't want the wrapper, use `list --pick` inline:

```bash
cd "$(doma list -t crystal --pick)"
```

`--pick` prints exactly one path: the only match if there's one, an interactive picker if you're on a TTY, or the most-recent match (with a stderr advisory) if you're piping.

## Verifying

```bash
doma doctor
```

The `doctor` command reports where doma's database lives, whether your config parses, and the schema version. It doesn't directly check whether the wrapper is loaded — the easiest test is to run `doma cd` and see if your shell actually moved.

## Uninstalling the wrapper

The block in your rc file is bracketed by sentinel comments:

```
# >>> doma shell integration >>>
…
# <<< doma shell integration <<<
```

Delete those lines (and the `eval` between them) and restart your shell.
