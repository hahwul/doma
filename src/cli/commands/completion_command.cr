require "option_parser"
require "../../utils/errors"

module Doma::CLI
  # Emits shell completion scripts for bash, zsh, and fish. Mirrors the
  # `setup init` pattern: the binary prints the script, the user pipes
  # it into a sourcing context.
  #
  #   doma setup completion bash > /etc/bash_completion.d/doma
  #   doma setup completion zsh  > ~/.zsh/completions/_doma
  #   doma setup completion fish > ~/.config/fish/completions/doma.fish
  #
  # Tag values complete dynamically by shelling out to `doma tags
  # --names` — that way new tags show up in completion the moment they
  # exist, no rebuild needed.
  class CompletionCommand
    SUPPORTED = %w[bash zsh fish]

    def run(args : Array(String))
      shell : String? = nil

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma setup completion <bash|zsh|fish>"
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Print a completion script for the given shell."
          STDOUT.puts ""
          STDOUT.puts "Bash:  doma setup completion bash > /etc/bash_completion.d/doma"
          STDOUT.puts "Zsh:   doma setup completion zsh  > \"${fpath[1]}/_doma\""
          STDOUT.puts "Fish:  doma setup completion fish > ~/.config/fish/completions/doma.fish"
          STDOUT.puts ""
          STDOUT.puts "Tags complete dynamically via `doma tags --names`, so"
          STDOUT.puts "freshly-added tags show up immediately."
          exit 0
        end
        p.unknown_args do |before, after|
          shell ||= before.first? || after.first?
        end
      end
      parser.parse(args)

      target = shell
      raise Doma::ValidationError.new("shell is required (one of: #{SUPPORTED.join(", ")})") unless target

      case target
      when "bash" then STDOUT.puts bash_script
      when "zsh"  then STDOUT.puts zsh_script
      when "fish" then STDOUT.puts fish_script
      else
        raise Doma::ValidationError.new(
          "unsupported shell '#{target}' (supported: #{SUPPORTED.join(", ")})"
        )
      end
    end

    # Top-level commands shared across all three completion scripts.
    # Keep this in lockstep with the dispatch table in `runner.cr`.
    private COMMANDS = %w[
      add mark rm prune move tags rename list info cd stats run export import setup doctor config trash version help
    ]

    # Commands whose first positional is a tag — completion shells these
    # out to `doma tags --names`. Picked deliberately conservative: only
    # commands where the first positional is *unambiguously* a tag.
    private TAG_FIRST_ARG = %w[cd run rename]

    private def bash_script : String
      <<-BASH
        # doma completion (bash)
        # Install: doma setup completion bash > /etc/bash_completion.d/doma
        #     or:  source <(doma setup completion bash)
        _doma() {
          local cur prev words cword
          if declare -F _init_completion >/dev/null 2>&1; then
            _init_completion || return
          else
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"
            words=("${COMP_WORDS[@]}")
            cword=$COMP_CWORD
          fi

          local cmds="#{COMMANDS.join(' ')}"

          # First positional → top-level command.
          if [ "$cword" -eq 1 ]; then
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
            return
          fi

          local cmd="${words[1]}"

          # Flags that take a tag argument across multiple commands.
          case "$prev" in
            -t|--tag)
              local tags
              tags=$(command doma tags --names 2>/dev/null)
              COMPREPLY=( $(compgen -W "$tags" -- "$cur") )
              return
              ;;
            --by)
              COMPREPLY=( $(compgen -W "path recent used recency tag" -- "$cur") )
              return
              ;;
            --ttl)
              COMPREPLY=( $(compgen -W "30m 1h 4h 1d 7d 2w 30d" -- "$cur") )
              return
              ;;
          esac

          # First positional after the subcommand: complete tags for
          # commands that take a tag there. Skip if the user is typing
          # a flag (cur starts with `-`) — they want flag completion,
          # not value completion, even at this position.
          if [ "$cword" -eq 2 ] && [[ "$cur" != -* ]]; then
            case "$cmd" in
              cd|run|rename)
                local tags
                tags=$(command doma tags --names 2>/dev/null)
                COMPREPLY=( $(compgen -W "$tags" -- "$cur") )
                return
                ;;
              add|move|rm|info)
                COMPREPLY=( $(compgen -d -- "$cur") )
                return
                ;;
              import)
                COMPREPLY=( $(compgen -f -- "$cur") )
                return
                ;;
              setup)
                COMPREPLY=( $(compgen -W "install init completion" -- "$cur") )
                return
                ;;
              config)
                COMPREPLY=( $(compgen -W "get set unset list edit path" -- "$cur") )
                return
                ;;
              trash)
                COMPREPLY=( $(compgen -W "list restore empty" -- "$cur") )
                return
                ;;
            esac
          fi

          # Second positional after `config <action>` → key name.
          if [ "$cword" -eq 3 ] && [ "$cmd" = "config" ]; then
            COMPREPLY=( $(compgen -W "db_path selector auto_tag.basename auto_tag.git" -- "$cur") )
            return
          fi

          # Per-command flag completion. Lists are intentionally narrow —
          # the most-used flags first; rare ones still work via tab-twice.
          case "$cmd" in
            add)    COMPREPLY=( $(compgen -W "-t --tag --ttl --tmp --auto-tag --no-auto-tag --git-tag --no-git-tag --dry-run -h --help" -- "$cur") ) ;;
            mark)   COMPREPLY=( $(compgen -W "-t --tag -p --path -h --help" -- "$cur") ) ;;
            rm)     COMPREPLY=( $(compgen -W "-t --tag --hard -h --help" -- "$cur") ) ;;
            prune)  COMPREPLY=( $(compgen -W "--gone --expired -h --help" -- "$cur") ) ;;
            move)   COMPREPLY=( $(compgen -W "--allow-missing -h --help" -- "$cur") ) ;;
            tags)   COMPREPLY=( $(compgen -W "--names --tree --json -0 -h --help" -- "$cur") ) ;;
            list)   COMPREPLY=( $(compgen -W "-t --tag --by --check --include-expired --json --paths -0 --pick --query --first --builtin -h --help" -- "$cur") ) ;;
            info)   COMPREPLY=( $(compgen -W "--json -h --help" -- "$cur") ) ;;
            cd)     COMPREPLY=( $(compgen -W "-h --help" -- "$cur") ) ;;
            stats)  COMPREPLY=( $(compgen -W "--top --recent --used --json -h --help" -- "$cur") ) ;;
            run)    COMPREPLY=( $(compgen -W "-t --tag --fail-fast --parallel --jobs --no-header -h --help" -- "$cur") ) ;;
            export) COMPREPLY=( $(compgen -W "--json --yaml -h --help" -- "$cur") ) ;;
            import) COMPREPLY=( $(compgen -W "--merge --replace --yes -h --help" -- "$cur") ) ;;
            setup)  COMPREPLY=( $(compgen -W "install init completion" -- "$cur") ) ;;
            doctor) COMPREPLY=( $(compgen -W "-h --help" -- "$cur") ) ;;
            config) COMPREPLY=( $(compgen -W "get set unset list edit path -h --help" -- "$cur") ) ;;
            trash)  COMPREPLY=( $(compgen -W "list restore empty --merge --older -h --help" -- "$cur") ) ;;
            *) ;;
          esac
        }
        complete -F _doma doma
        BASH
    end

    private def zsh_script : String
      <<-ZSH
        #compdef doma
        # doma completion (zsh)
        # Install: doma setup completion zsh > "${fpath[1]}/_doma"

        _doma() {
          local -a top_cmds
          top_cmds=(
            'add:Register a path with tags'
            'mark:Tag cwd with temporary (7d) tags'
            'rm:Remove tag(s) or the path itself'
            'move:Move a registered path (tags carry over)'
            'tags:List all tags with counts'
            'rename:Rename or merge a tag'
            'list:List/search directories'
            'cd:Resolve a directory (tag or short_id prefix)'
            'stats:Top tags and recent paths'
            'run:Run a command in every tagged directory'
            'export:Dump the database'
            'import:Load a snapshot'
            'setup:install / init / doctor / completion'
            'config:get / set / list — settings'
            'trash:list / restore / empty — recover from rm'
            'version:Print version'
            'help:Show help'
          )

          if (( CURRENT == 2 )); then
            _describe 'doma command' top_cmds
            return
          fi

          local cmd=$words[2]
          local -a tags
          _doma_tags() {
            tags=("${(@f)$(command doma tags --names 2>/dev/null)}")
            _wanted tags expl 'doma tag' compadd -a tags
          }

          case $cmd in
            cd|run|rename)
              if (( CURRENT == 3 )); then
                _doma_tags
                return
              fi
              ;;
            add|move|rm|info)
              if (( CURRENT == 3 )); then
                _path_files -/
                return
              fi
              ;;
            import)
              if (( CURRENT == 3 )); then
                _files
                return
              fi
              ;;
            setup)
              if (( CURRENT == 3 )); then
                _values 'setup action' install init completion
                return
              fi
              ;;
            config)
              if (( CURRENT == 3 )); then
                _values 'config action' get set unset list edit path
                return
              fi
              if (( CURRENT == 4 )); then
                case $words[3] in
                  get|set|unset)
                    _values 'config key' db_path selector auto_tag.basename auto_tag.git
                    return
                    ;;
                esac
              fi
              ;;
            trash)
              if (( CURRENT == 3 )); then
                _values 'trash action' list restore empty
                return
              fi
              ;;
          esac

          # Flag-value completion across commands.
          case $words[CURRENT-1] in
            -t|--tag) _doma_tags; return ;;
            --by)     _values 'sort key' path recent used recency tag; return ;;
            --ttl)    _values 'duration' 30m 1h 4h 1d 7d 2w 30d; return ;;
          esac

          # Per-command flag pool.
          local -a flags
          case $cmd in
            add)    flags=(-t --tag --ttl --tmp --auto-tag --no-auto-tag --git-tag --no-git-tag --dry-run -h --help) ;;
            mark)   flags=(-t --tag -p --path -h --help) ;;
            rm)     flags=(-t --tag --hard -h --help) ;;
            prune)  flags=(--gone --expired -h --help) ;;
            move)   flags=(--allow-missing -h --help) ;;
            tags)   flags=(--names --tree --json -0 -h --help) ;;
            list)   flags=(-t --tag --by --check --include-expired --json --paths -0 --pick --query --first --builtin -h --help) ;;
            info)   flags=(--json -h --help) ;;
            cd)     flags=(-h --help) ;;
            stats)  flags=(--top --recent --used --json -h --help) ;;
            run)    flags=(-t --tag --fail-fast --parallel --jobs --no-header -h --help) ;;
            export) flags=(--json --yaml -h --help) ;;
            import) flags=(--merge --replace --yes -h --help) ;;
            doctor) flags=(-h --help) ;;
          esac
          (( ${#flags} )) && compadd -a flags
        }

        compdef _doma doma
        ZSH
    end

    private def fish_script : String
      lines = [] of String
      lines << "# doma completion (fish)"
      lines << "# Install: doma setup completion fish > ~/.config/fish/completions/doma.fish"
      lines << ""
      lines << "complete -c doma -f"
      lines << ""

      # Top-level commands appear only when no subcommand is set yet.
      cmd_descs = {
        "add"     => "Register a path with tags",
        "mark"    => "Tag cwd with temporary (7d) tags",
        "rm"      => "Remove tag(s) or the path itself",
        "prune"   => "Bulk-delete missing paths or expired tags",
        "move"    => "Move a registered path",
        "tags"    => "List all tags with counts",
        "rename"  => "Rename or merge a tag",
        "list"    => "List/search directories",
        "info"    => "Show one entry's details (default: cwd)",
        "cd"      => "Resolve a directory (via shell wrapper)",
        "stats"   => "Top tags and recent paths",
        "run"     => "Run a command in every tagged directory",
        "export"  => "Dump the database",
        "import"  => "Load a snapshot",
        "setup"   => "install / init / completion",
        "doctor"  => "Check the install (paths, config, DB)",
        "config"  => "get / set / list — settings",
        "trash"   => "list / restore / empty — recover from rm",
        "version" => "Print version",
        "help"    => "Show help",
      }
      cmd_descs.each do |cmd, desc|
        lines << "complete -c doma -n '__fish_use_subcommand' -a '#{cmd}' -d '#{desc}'"
      end
      lines << ""

      # Tag-as-first-arg subcommands.
      TAG_FIRST_ARG.each do |sub|
        lines << "complete -c doma -n '__fish_seen_subcommand_from #{sub}' " \
                 "-a '(command doma tags --names 2>/dev/null)' -d 'tag'"
      end
      lines << ""

      # -t/--tag value completion across the suite.
      lines << "complete -c doma -s t -l tag -x -a '(command doma tags --names 2>/dev/null)' -d 'tag'"
      lines << "complete -c doma -l by -x -a 'path recent used recency tag' -d 'sort key'"
      lines << "complete -c doma -l ttl -x -a '30m 1h 4h 1d 7d 2w 30d' -d 'duration'"
      lines << ""

      # Setup actions.
      lines << "complete -c doma -n '__fish_seen_subcommand_from setup; and not __fish_seen_subcommand_from install init completion' " \
               "-a 'install init completion' -d 'setup action'"
      lines << ""

      # Config actions and keys.
      lines << "complete -c doma -n '__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from get set unset list edit path' " \
               "-a 'get set unset list edit path' -d 'config action'"
      lines << "complete -c doma -n '__fish_seen_subcommand_from get set unset' " \
               "-a 'db_path selector auto_tag.basename auto_tag.git' -d 'config key'"
      lines << ""

      # Trash actions.
      lines << "complete -c doma -n '__fish_seen_subcommand_from trash; and not __fish_seen_subcommand_from list restore empty' " \
               "-a 'list restore empty' -d 'trash action'"
      lines << ""

      # Per-command flag pool. Kept terse — fish handles typing the rest.
      flag_table = {
        "add"    => %w[--tag --ttl --tmp --auto-tag --no-auto-tag --git-tag --no-git-tag --dry-run],
        "rm"     => %w[--tag --hard],
        "prune"  => %w[--gone --expired],
        "move"   => %w[--allow-missing],
        "tags"   => %w[--names --tree --json],
        "list"   => %w[--tag --by --check --include-expired --json --paths --pick --query --first --builtin],
        "info"   => %w[--json],
        "stats"  => %w[--top --recent --used --json],
        "mark"   => %w[--tag --path],
        "run"    => %w[--tag --fail-fast --parallel --jobs --no-header],
        "export" => %w[--json --yaml],
        "import" => %w[--merge --replace --yes],
      }
      flag_table.each do |sub, flags|
        flags.each do |f|
          long = f.lstrip('-')
          lines << "complete -c doma -n '__fish_seen_subcommand_from #{sub}' -l #{long}"
        end
      end

      lines.join("\n") + "\n"
    end
  end
end
