+++
title = "Shell integration"
description = "Make doma cd actually change your shell's working directory."
weight = 3
+++

`doma cd` is a child process. It can't change its parent shell's working directory — that's a POSIX rule, not a doma limitation. To work around it, doma ships a tiny shell wrapper that captures the printed path and runs `cd` for you. The same pattern zoxide, starship, and mise use.

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

`doma cd` still prints the resolved path, so you can use it inline:

```bash
cd "$(doma cd crystal)"
```

The first time `doma cd` notices its output is going straight to a TTY (instead of being captured by the wrapper), it emits a one-time stderr hint pointing at `doma setup install`. The hint is suppressed on subsequent runs via a marker file in `~/.config/doma/`.

## Verifying

```bash
doma setup doctor
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
