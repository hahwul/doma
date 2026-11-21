require "option_parser"
require "../../utils/errors"
require "./config_command"
require "./list_command"
require "./shell_arg"
require "./sweep_args"

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

      case ShellArg.validate!(shell)
      when "bash" then STDOUT.puts bash_script
      when "zsh"  then STDOUT.puts zsh_script
      when "fish" then STDOUT.puts fish_script
      end
    end

    # ------------------------------------------------------------------
    # COMMAND_SPEC — single source of truth for every top-level command.
    # Adding a new subcommand is one row here; the bash/zsh/fish
    # generators below read this table and emit their respective syntax.
    #
    # Fields per row:
    #   name        the subcommand keyword (matches runner.cr dispatch)
    #   desc        short description (one canonical line, used by zsh
    #               top_cmds and fish -d annotations)
    #   flags       complete flag list (short + long + -h/--help). Used
    #               verbatim by bash and zsh flag pools; fish filters
    #               to long-form only, dropping --help.
    #   actions     sub-action keywords (e.g. `install init completion`
    #               for setup). Completed only as the word after the
    #               command (bash case arm, zsh _values, fish -a).
    # ------------------------------------------------------------------

    private record CmdSpec,
      name : String,
      desc : String,
      flags : Array(String),
      actions : Array(String) = [] of String

    private COMMAND_SPEC = [
      CmdSpec.new("add", "Register a path with tags",
        %w[-t --tag --ttl --tmp --auto-tag --no-auto-tag --git-tag --no-git-tag --project-tag --no-project-tag -r --recursive -n --dry-run --json -h --help]),
      CmdSpec.new("mark", "Tag cwd with temporary (7d) tags",
        %w[-t --tag -p --path --ttl -h --help]),
      CmdSpec.new("rm", "Remove tag(s) or the path itself",
        %w[-t --tag --hard -h --help]),
      CmdSpec.new("prune", "Bulk-delete missing paths or expired tags",
        %w[--gone --expired --hard -h --help]),
      CmdSpec.new("move", "Move a registered path (tags carry over)",
        %w[--allow-missing -h --help]),
      CmdSpec.new("tags", "List all tags with counts",
        %w[--names --tree --all --json -0 --print0 -h --help]),
      CmdSpec.new("rename", "Rename or merge a tag",
        [] of String),
      CmdSpec.new("list", "List/search directories",
        %w[-t --tag -x --exclude --by --check --include-expired --json --paths -0 --print0 --pick --query --first --builtin -h --help]),
      CmdSpec.new("tui", "Fuzzy-find directories interactively",
        %w[-t --tag --query -h --help]),
      CmdSpec.new("info", "Show one entry's details (default: cwd)",
        %w[--json -h --help]),
      CmdSpec.new("cd", "Resolve a directory by tag (shell wrapper)",
        %w[-h --help]),
      CmdSpec.new("stats", "Top tags and recent paths",
        %w[--top --recent --used --group-by-prefix --json -h --help]),
      CmdSpec.new("status", "Git status across tagged repos",
        %w[-t --tag -x --exclude --dirty --jobs --json -h --help]),
      CmdSpec.new("run", "Run a command in every tagged directory",
        %w[-t --tag -x --exclude --fail-fast --parallel --jobs --no-header -n --dry-run --json -h --help]),
      CmdSpec.new("export", "Dump the database",
        %w[--json --yaml --portable -o --output -h --help]),
      CmdSpec.new("import", "Load a snapshot",
        %w[--merge --replace --clone -y --yes -n --dry-run -h --help]),
      CmdSpec.new("setup", "install / init / completion",
        [] of String, %w[install init completion]),
      CmdSpec.new("doctor", "Check the install (paths, config, DB)",
        %w[-h --help]),
      CmdSpec.new("config", "get / set / list — settings",
        %w[-h --help], ConfigCommand::ACTIONS),
      CmdSpec.new("trash", "list / restore / empty — recover from rm",
        %w[--merge --older --json -h --help], %w[list restore empty]),
      CmdSpec.new("version", "Print version",
        [] of String),
      CmdSpec.new("help", "Show help",
        [] of String),
    ]

    # Commands whose first positional is a tag — completion shells these
    # out to `doma tags --names`. Picked deliberately conservative: only
    # commands where the first positional is *unambiguously* a tag.
    private TAG_FIRST_ARG = %w[cd run rename status]

    # Aliases runner.cr dispatches to a canonical command. Every per-command
    # arm also matches these, so `ls`/`mv`/`remove` complete like the original.
    private ALIASES = {"list" => %w[ls], "move" => %w[mv], "rm" => %w[remove]}

    # Subcommands whose selector accepts `@sets` next to tags (and the
    # space-joined names to offer there).
    private SET_CMDS  = %w[list ls run status]
    private SET_NAMES = SweepArgs::SETS.keys.join(' ')

    # Subcommands whose first positional is a known directory path.
    private PATH_FIRST_ARG = %w[add move rm info]

    # Subcommands whose first positional is a filesystem path (any file,
    # not just registered directories).
    private FILE_FIRST_ARG = %w[import]

    # Known config keys for `config get/set/unset` value completion —
    # sourced from the config command itself so the two can't drift.
    private CONFIG_KEYS = ConfigCommand::KEYS

    # Argument-value enums shared by every shell. `--by` values come
    # from the list command so completion can't lag the parser.
    private BY_VALUES  = ListCommand::BY_CHOICES
    private TTL_VALUES = %w[30m 1h 4h 1d 7d 2w 30d]

    # Flags whose value is free-form (a number, duration or query): offer
    # nothing rather than the flag pool.
    private FREE_VALUE_FLAGS = %w[--jobs --top --recent --used --older --query]

    # `names` plus their aliases, in shell-case order.
    private def with_aliases(names : Array(String)) : Array(String)
      names.flat_map { |n| [n] + ALIASES.fetch(n, [] of String) }
    end

    # Every command name (aliases included) whose flags contain `flag`.
    private def cmds_with_flag(flag : String) : String
      with_aliases(COMMAND_SPEC.select(&.flags.includes?(flag)).map(&.name)).join(' ')
    end

    # ------------------------------------------------------------------
    # Per-shell generators. Native idioms (compgen / _values /
    # `complete -c`) stay distinct — the syntactic distance is large
    # enough that a unified emitter would obscure more than dedupe.
    # ------------------------------------------------------------------

    private def bash_script : String
      <<-BASH
        # doma completion (bash)
        # Install: doma setup completion bash > /etc/bash_completion.d/doma
        #     or:  source <(doma setup completion bash)

        # Tag names, plus the `@sets` for commands whose selector takes them.
        __doma_tag_words() {
          command doma tags --names 2>/dev/null
          case "$1" in
            #{SET_CMDS.join('|')}) printf '%s\\n' #{SET_NAMES} ;;
          esac
        }

        # Readline replaces only the text after the last COMP_WORDBREAKS
        # char (`:` in `lang:crystal`, `@` in `@failed`, `user@host` paths)
        # while doma completes the whole word, so strip that prefix from
        # each candidate. Reads `cur` from the calling `_doma`.
        __doma_ltrim() {
          local breaks=""
          [[ "$COMP_WORDBREAKS" == *:* ]] && breaks+=":"
          [[ "$COMP_WORDBREAKS" == *@* ]] && breaks+="@"
          [[ -n "$breaks" && "$cur" == *[$breaks]* ]] || return 0
          local prefix="${cur%"${cur##*[$breaks]}"}" i
          for i in "${!COMPREPLY[@]}"; do
            COMPREPLY[$i]="${COMPREPLY[$i]#"$prefix"}"
          done
        }

        # COMPREPLY from a word list, trimmed for readline.
        __doma_reply() {
          COMPREPLY=( $(compgen -W "$1" -- "$cur") )
          __doma_ltrim
        }

        # COMPREPLY from `compgen -d|-f|-c`: split on newlines only (names
        # may hold spaces), and let readline escape them and append `/` to
        # directories. bash 3.2 has no compopt, so escape them here instead.
        __doma_paths() {
          local IFS=$'\\n' i
          COMPREPLY=( $(compgen "$1" -- "$cur") )
          __doma_ltrim
          compopt -o filenames 2>/dev/null && return
          for i in "${!COMPREPLY[@]}"; do
            COMPREPLY[$i]=$(printf '%q' "${COMPREPLY[$i]}")
          done
        }

        _doma() {
          local cur prev words cword
          if declare -F _init_completion >/dev/null 2>&1; then
            # `-n :@` keeps `lang:crystal` and `@failed` one word (both are
            # in COMP_WORDBREAKS).
            _init_completion -n :@ || return
          else
            # Rebuild words from the raw line: COMP_WORDS is split at every
            # COMP_WORDBREAKS char, which would cut `@failed` in two. No -r:
            # `d/with\\ space` stays one (unescaped) word.
            local line="${COMP_LINE:0:COMP_POINT}"
            read -a words <<< "$line"
            [[ ${#words[@]} -eq 0 || ( "$line" == *[[:space:]] && "$line" != *'\\ ' ) ]] && words+=("")
            cword=$(( ${#words[@]} - 1 ))
            cur="${words[cword]}"
            prev="${words[cword-1]}"
          fi

          local cmds="#{COMMAND_SPEC.map(&.name).join(' ')}"

          # First positional → top-level command.
          if [ "$cword" -eq 1 ]; then
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
            return
          fi

          local cmd="${words[1]}"

          # Past `--` the words belong to the wrapped command (`run TAG --
          # cmd`): a command name, then files, never doma's own flags.
          local i move_flags=0
          for (( i = 2; i < cword; i++ )); do
            case "${words[i]}" in
              --)
                if [ "$i" -eq $(( cword - 1 )) ]; then __doma_paths -c; else __doma_paths -f; fi
                return
                ;;
              --allow-missing) move_flags=$(( move_flags + 1 )) ;;
            esac
          done

          # Flags that take a tag argument across multiple commands.
          case "$prev" in
            -t|--tag|-x|--exclude)
              __doma_reply "$(__doma_tag_words "$cmd")"
              return
              ;;
            -p|--path)
              __doma_paths -d
              return
              ;;
            -o|--output)
              __doma_paths -f
              return
              ;;
            #{FREE_VALUE_FLAGS.join('|')})
              COMPREPLY=()
              return
              ;;
            --by)
              __doma_reply "#{BY_VALUES.join(' ')}"
              return
              ;;
            --ttl)
              __doma_reply "#{TTL_VALUES.join(' ')}"
              return
              ;;
          esac

          # Complete the first positional, and the destination for move.
          local last_positional=2
          case "$cmd" in
            #{with_aliases(["move"]).join('|')}) last_positional=$(( 3 + move_flags )) ;;
          esac
          if (( cword >= 2 && cword <= last_positional )) && [[ "$cur" != -* ]]; then
            case "$cmd" in
              #{with_aliases(TAG_FIRST_ARG).join('|')})
                __doma_reply "$(__doma_tag_words "$cmd")"
                return
                ;;
              #{with_aliases(PATH_FIRST_ARG).join('|')})
                __doma_paths -d
                return
                ;;
              #{with_aliases(FILE_FIRST_ARG).join('|')})
                __doma_paths -f
                return
                ;;
        #{bash_first_arg_action_cases.chomp}
            esac
          fi

          # Second positional after `config <action>` → key name.
          if [ "$cword" -eq 3 ] && [ "$cmd" = "config" ]; then
            COMPREPLY=( $(compgen -W "#{CONFIG_KEYS.join(' ')}" -- "$cur") )
            return
          fi

          # `setup <action>` → shell name (every setup action takes one).
          if [ "$cword" -eq 3 ] && [ "$cmd" = "setup" ]; then
            COMPREPLY=( $(compgen -W "#{ShellArg::SUPPORTED.join(' ')}" -- "$cur") )
            return
          fi

          # Per-command flag completion. Lists are intentionally narrow —
          # the most-used flags first; rare ones still work via tab-twice.
          case "$cmd" in
        #{bash_flag_pool_body.chomp}
            *) ;;
          esac
        }
        complete -F _doma doma
        BASH
    end

    # Builds the inner `setup) config) trash)` arms of the bash
    # first-positional `case "$cmd"` block — one arm per command whose
    # second word is an action keyword (setup install / config get / …).
    private def bash_first_arg_action_cases : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          next if spec.actions.empty?
          sb << "      #{spec.name})\n"
          sb << "        COMPREPLY=( $(compgen -W \"#{spec.actions.join(' ')}\" -- \"$cur\") )\n"
          sb << "        return\n"
          sb << "        ;;\n"
        end
      end
    end

    # Builds the per-command `cmd) COMPREPLY=...` arms of the bash flag
    # pool. Actions are left out: they complete at cword 2 above, so here
    # they could only be re-offered as values. Commands without flags are
    # omitted — the `*) ;;` default catches them.
    private def bash_flag_pool_body : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          next if spec.flags.empty?
          label = "#{with_aliases([spec.name]).join('|')})".ljust(8)
          sb << "    #{label}COMPREPLY=( $(compgen -W \"#{spec.flags.join(' ')}\" -- \"$cur\") ) ;;\n"
        end
      end
    end

    private def zsh_script : String
      <<-ZSH
        #compdef doma
        # doma completion (zsh)
        # Install: doma setup completion zsh > "${fpath[1]}/_doma"

        _doma() {
          local -a top_cmds
          top_cmds=(
        #{zsh_top_cmds_body.chomp}
          )

          if (( CURRENT == 2 )); then
            _describe 'doma command' top_cmds
            return
          fi

          local cmd=$words[2]
          local -a tags
          _doma_tags() {
            tags=("${(@f)$(command doma tags --names 2>/dev/null)}")
            case $cmd in
              #{SET_CMDS.join('|')}) tags+=(#{SET_NAMES}) ;;
            esac
            _wanted tags expl 'doma tag' compadd -a tags
          }

          # Past `--` the words belong to the wrapped command (`run TAG -- cmd`).
          local dd=${words[(i)--]}
          if (( dd > 2 && dd < CURRENT )); then
            shift dd words
            (( CURRENT -= dd ))
            _normal
            return
          fi

          # Complete the first positional, and the destination for move.
          local last_positional=3
          case $cmd in
            #{with_aliases(["move"]).join('|')})
              last_positional=4
              local i
              for (( i = 3; i < CURRENT; i++ )); do
                if [[ $words[i] = --allow-missing ]]; then
                  (( last_positional += 1 ))
                fi
              done
              ;;
          esac
          case $cmd in
            #{with_aliases(TAG_FIRST_ARG).join('|')})
              if (( CURRENT == 3 )) && [[ $PREFIX != -* ]]; then
                _doma_tags
                return
              fi
              ;;
            #{with_aliases(PATH_FIRST_ARG).join('|')})
              if (( CURRENT >= 3 && CURRENT <= last_positional )) && [[ $PREFIX != -* ]]; then
                _path_files -/
                return
              fi
              ;;
            #{with_aliases(FILE_FIRST_ARG).join('|')})
              if (( CURRENT == 3 )) && [[ $PREFIX != -* ]]; then
                _files
                return
              fi
              ;;
        #{zsh_action_cases.chomp}
          esac

          # Flag-value completion across commands.
          case $words[CURRENT-1] in
            -t|--tag|-x|--exclude) _doma_tags; return ;;
            --by)     _values 'sort key' #{BY_VALUES.join(' ')}; return ;;
            --ttl)    _values 'duration' #{TTL_VALUES.join(' ')}; return ;;
            -p|--path)   _path_files -/; return ;;
            -o|--output) _files; return ;;
            #{FREE_VALUE_FLAGS.join('|')}) return 1 ;;
          esac

          # Per-command flag pool.
          local -a flags
          case $cmd in
        #{zsh_flag_pool_body.chomp}
          esac
          (( ${#flags} )) && compadd -a flags
        }

        # Autoloaded from fpath, this file *is* `_doma`'s body: call it so
        # the first TAB completes. Sourced directly, register it instead.
        if [ "$funcstack[1]" = "_doma" ]; then
          _doma "$@"
        else
          compdef _doma doma
        fi
        ZSH
    end

    # zsh `top_cmds` entries — one `'name:desc'` per command. Quotes are
    # the zsh single-quote form. Unlike fish, zsh has no in-quote escape
    # for `'` (a bare `\'` just ends the string early — see "info"'s
    # "entry's" description) — the POSIX way to embed one is to close
    # the quote, splice in an escaped quote, and reopen: `'\''`.
    private def zsh_top_cmds_body : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          escaped = spec.desc.gsub('\'', "'\\''")
          sb << "    '#{spec.name}:#{escaped}'\n"
        end
      end
    end

    # zsh action-dispatch arms (setup/config/trash). config also drops
    # into a CURRENT==4 sub-case for the config key list, setup for the
    # shell name.
    private def zsh_action_cases : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          next if spec.actions.empty?
          sb << "    #{spec.name})\n"
          sb << "      if (( CURRENT == 3 )); then\n"
          sb << "        _values '#{spec.name} action' #{spec.actions.join(' ')}\n"
          sb << "        return\n"
          sb << "      fi\n"
          if spec.name == "config"
            sb << "      if (( CURRENT == 4 )); then\n"
            sb << "        case $words[3] in\n"
            sb << "          get|set|unset)\n"
            sb << "            _values 'config key' #{CONFIG_KEYS.join(' ')}\n"
            sb << "            return\n"
            sb << "            ;;\n"
            sb << "        esac\n"
            sb << "      fi\n"
          end
          if spec.name == "setup"
            sb << "      if (( CURRENT == 4 )); then\n"
            sb << "        _values 'shell' #{ShellArg::SUPPORTED.join(' ')}\n"
            sb << "        return\n"
            sb << "      fi\n"
          end
          sb << "      ;;\n"
        end
      end
    end

    # zsh flag pool arms — one per command with flags. Action commands
    # reach theirs after the action word (`trash empty --older`).
    private def zsh_flag_pool_body : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          next if spec.flags.empty?
          label = "#{with_aliases([spec.name]).join('|')})".ljust(8)
          sb << "    #{label}flags=(#{spec.flags.join(' ')}) ;;\n"
        end
      end
    end

    # Complete each command's positional slots, including aliases.
    private def fish_positional(sub : String) : String
      max = sub.in?({"move", "rename"}) ? 3 : 2
      words = "commandline -opc"
      words = "string match -v -- --allow-missing (#{words})" if sub == "move"
      "__fish_seen_subcommand_from #{with_aliases([sub]).join(' ')}; and test (count (#{words})) -le #{max}"
    end

    private def fish_script : String
      lines = [] of String
      lines << "# doma completion (fish)"
      lines << "# Install: doma setup completion fish > ~/.config/fish/completions/doma.fish"
      lines << ""
      lines << "complete -c doma -f"
      lines << ""

      # Top-level commands appear only when no subcommand is set yet.
      # Apostrophes in descriptions (e.g. `entry's`) need escaping —
      # fish's `-d` value is a single-quoted string.
      COMMAND_SPEC.each do |spec|
        escaped = spec.desc.gsub('\'', "\\'")
        lines << "complete -c doma -n '__fish_use_subcommand' -a '#{spec.name}' -d '#{escaped}'"
      end
      lines << ""

      # Tag-as-first-arg subcommands.
      TAG_FIRST_ARG.each do |sub|
        lines << "complete -c doma -n '#{fish_positional(sub)}' " \
                 "-a '(command doma tags --names 2>/dev/null)' -d 'tag'"
      end
      # Path-as-first-arg subcommands and path-valued flags
      # (`complete -c doma -f` above turns file completion off).
      PATH_FIRST_ARG.each do |sub|
        lines << "complete -c doma -n '#{fish_positional(sub)}' -a '(__fish_complete_directories)'"
      end
      FILE_FIRST_ARG.each do |sub|
        lines << "complete -c doma -n '#{fish_positional(sub)}' -F"
      end
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{cmds_with_flag("--path")}' -s p -l path -x -a '(__fish_complete_directories)'"
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{cmds_with_flag("--output")}' -s o -l output -r -F"
      lines << ""

      # -t/--tag value completion, only where the command takes it.
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{cmds_with_flag("--tag")}' -s t -l tag -x -a '(command doma tags --names 2>/dev/null)' -d 'tag'"
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{SET_CMDS.join(' ')}' -s x -l exclude -x -a '(command doma tags --names 2>/dev/null)' -d 'exclude tag'"
      # `@sets` next to tags wherever the selector takes them.
      sets = "-a '#{SET_NAMES}' -d 'set'"
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{SET_CMDS.join(' ')}' -s t -l tag -x #{sets}"
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{SET_CMDS.join(' ')}' -s x -l exclude -x #{sets}"
      (TAG_FIRST_ARG & SET_CMDS).each do |sub|
        lines << "complete -c doma -n '#{fish_positional(sub)}' #{sets}"
      end
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{cmds_with_flag("--by")}' -l by -x -a '#{BY_VALUES.join(' ')}' -d 'sort key'"
      lines << "complete -c doma -n '__fish_seen_subcommand_from #{cmds_with_flag("--ttl")}' -l ttl -x -a '#{TTL_VALUES.join(' ')}' -d 'duration'"
      lines << ""

      # Action dispatchers (setup, config, trash). Plus the secondary
      # `config get/set/unset` → key dispatcher.
      COMMAND_SPEC.each do |spec|
        next if spec.actions.empty?
        actions_str = spec.actions.join(' ')
        lines << "complete -c doma -n '__fish_seen_subcommand_from #{spec.name}; and not __fish_seen_subcommand_from #{actions_str}' " \
                 "-a '#{actions_str}' -d '#{spec.name} action'"
      end
      lines << "complete -c doma -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from get set unset; and test (count (commandline -opc)) -le 3' " \
               "-a '#{CONFIG_KEYS.join(' ')}' -d 'config key'"
      lines << "complete -c doma -n '__fish_seen_subcommand_from setup; and __fish_seen_subcommand_from install init completion; and test (count (commandline -opc)) -le 3' " \
               "-a '#{ShellArg::SUPPORTED.join(' ')}' -d 'shell'"
      lines << ""

      # Per-command long-flag pool. fish handles -h/--help natively, and
      # short flags aren't part of its per-command flag table.
      COMMAND_SPEC.each do |spec|
        spec.flags.each do |f|
          next unless f.starts_with?("--") && f != "--help"
          lines << "complete -c doma -n '__fish_seen_subcommand_from #{with_aliases([spec.name]).join(' ')}' -l #{f.lstrip('-')}"
        end
      end

      lines.join("\n") + "\n"
    end
  end
end
