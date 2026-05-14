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
    #               for setup). Used by bash's flag pool and by zsh /
    #               fish's separate _values / -a blocks.
    # ------------------------------------------------------------------

    private record CmdSpec,
      name : String,
      desc : String,
      flags : Array(String),
      actions : Array(String)

    private COMMAND_SPEC = [
      CmdSpec.new("add", "Register a path with tags",
        %w[-t --tag --ttl --tmp --auto-tag --no-auto-tag --git-tag --no-git-tag --dry-run -h --help], [] of String),
      CmdSpec.new("mark", "Tag cwd with temporary (7d) tags",
        %w[-t --tag -p --path -h --help], [] of String),
      CmdSpec.new("rm", "Remove tag(s) or the path itself",
        %w[-t --tag --hard -h --help], [] of String),
      CmdSpec.new("prune", "Bulk-delete missing paths or expired tags",
        %w[--gone --expired -h --help], [] of String),
      CmdSpec.new("move", "Move a registered path (tags carry over)",
        %w[--allow-missing -h --help], [] of String),
      CmdSpec.new("tags", "List all tags with counts",
        %w[--names --tree --json -0 -h --help], [] of String),
      CmdSpec.new("rename", "Rename or merge a tag",
        [] of String, [] of String),
      CmdSpec.new("list", "List/search directories",
        %w[-t --tag --by --check --include-expired --json --paths -0 --pick --query --first --builtin -h --help], [] of String),
      CmdSpec.new("info", "Show one entry's details (default: cwd)",
        %w[--json -h --help], [] of String),
      CmdSpec.new("cd", "Resolve a directory (tag or short_id prefix)",
        %w[-h --help], [] of String),
      CmdSpec.new("stats", "Top tags and recent paths",
        %w[--top --recent --used --json -h --help], [] of String),
      CmdSpec.new("run", "Run a command in every tagged directory",
        %w[-t --tag --fail-fast --parallel --jobs --no-header -h --help], [] of String),
      CmdSpec.new("export", "Dump the database",
        %w[--json --yaml -h --help], [] of String),
      CmdSpec.new("import", "Load a snapshot",
        %w[--merge --replace --yes -h --help], [] of String),
      CmdSpec.new("setup", "install / init / completion",
        [] of String, %w[install init completion]),
      CmdSpec.new("doctor", "Check the install (paths, config, DB)",
        %w[-h --help], [] of String),
      CmdSpec.new("config", "get / set / list — settings",
        %w[-h --help], %w[get set unset list edit path]),
      CmdSpec.new("trash", "list / restore / empty — recover from rm",
        %w[--merge --older -h --help], %w[list restore empty]),
      CmdSpec.new("version", "Print version",
        [] of String, [] of String),
      CmdSpec.new("help", "Show help",
        [] of String, [] of String),
    ]

    # Commands whose first positional is a tag — completion shells these
    # out to `doma tags --names`. Picked deliberately conservative: only
    # commands where the first positional is *unambiguously* a tag.
    private TAG_FIRST_ARG = %w[cd run rename]

    # Subcommands whose first positional is a known directory path.
    private PATH_FIRST_ARG = %w[add move rm info]

    # Subcommands whose first positional is a filesystem path (any file,
    # not just registered directories).
    private FILE_FIRST_ARG = %w[import]

    # Known config keys for `config get/set/unset` value completion.
    private CONFIG_KEYS = %w[db_path selector auto_tag.basename auto_tag.git]

    # Argument-value enums shared by every shell.
    private BY_VALUES  = %w[path recent used recency tag]
    private TTL_VALUES = %w[30m 1h 4h 1d 7d 2w 30d]

    # ------------------------------------------------------------------
    # Derivations from COMMAND_SPEC
    # ------------------------------------------------------------------

    # Filter a flag list down to long-form flags fish should complete:
    # `-h` and `--help` are handled by fish natively, and short flags
    # aren't part of fish's per-command flag table.
    private def fish_long_flags(flags : Array(String)) : Array(String)
      flags.select { |f| f.starts_with?("--") && f != "--help" }
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

          local cmds="#{COMMAND_SPEC.map(&.name).join(' ')}"

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
              COMPREPLY=( $(compgen -W "#{BY_VALUES.join(' ')}" -- "$cur") )
              return
              ;;
            --ttl)
              COMPREPLY=( $(compgen -W "#{TTL_VALUES.join(' ')}" -- "$cur") )
              return
              ;;
          esac

          # First positional after the subcommand: complete tags for
          # commands that take a tag there. Skip if the user is typing
          # a flag (cur starts with `-`) — they want flag completion,
          # not value completion, even at this position.
          if [ "$cword" -eq 2 ] && [[ "$cur" != -* ]]; then
            case "$cmd" in
              #{TAG_FIRST_ARG.join('|')})
                local tags
                tags=$(command doma tags --names 2>/dev/null)
                COMPREPLY=( $(compgen -W "$tags" -- "$cur") )
                return
                ;;
              #{PATH_FIRST_ARG.join('|')})
                COMPREPLY=( $(compgen -d -- "$cur") )
                return
                ;;
              #{FILE_FIRST_ARG.join('|')})
                COMPREPLY=( $(compgen -f -- "$cur") )
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
    # pool. Commands with neither flags nor actions are omitted — the
    # `*) ;;` default catches them.
    private def bash_flag_pool_body : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          words = spec.actions + spec.flags
          next if words.empty?
          label = "#{spec.name})".ljust(8)
          sb << "    #{label}COMPREPLY=( $(compgen -W \"#{words.join(' ')}\" -- \"$cur\") ) ;;\n"
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
            _wanted tags expl 'doma tag' compadd -a tags
          }

          case $cmd in
            #{TAG_FIRST_ARG.join('|')})
              if (( CURRENT == 3 )); then
                _doma_tags
                return
              fi
              ;;
            #{PATH_FIRST_ARG.join('|')})
              if (( CURRENT == 3 )); then
                _path_files -/
                return
              fi
              ;;
            #{FILE_FIRST_ARG.join('|')})
              if (( CURRENT == 3 )); then
                _files
                return
              fi
              ;;
        #{zsh_action_cases.chomp}
          esac

          # Flag-value completion across commands.
          case $words[CURRENT-1] in
            -t|--tag) _doma_tags; return ;;
            --by)     _values 'sort key' #{BY_VALUES.join(' ')}; return ;;
            --ttl)    _values 'duration' #{TTL_VALUES.join(' ')}; return ;;
          esac

          # Per-command flag pool.
          local -a flags
          case $cmd in
        #{zsh_flag_pool_body.chomp}
          esac
          (( ${#flags} )) && compadd -a flags
        }

        compdef _doma doma
        ZSH
    end

    # zsh `top_cmds` entries — one `'name:desc'` per command. Quotes are
    # the zsh single-quote form; descriptions don't contain `'` today.
    private def zsh_top_cmds_body : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          sb << "    '#{spec.name}:#{spec.desc}'\n"
        end
      end
    end

    # zsh action-dispatch arms (setup/config/trash). config also drops
    # into a CURRENT==4 sub-case for the config key list.
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
          sb << "      ;;\n"
        end
      end
    end

    # zsh flag pool arms — emitted only for commands with flags AND no
    # actions. Action commands are handled by the dispatcher arms above.
    private def zsh_flag_pool_body : String
      String.build do |sb|
        COMMAND_SPEC.each do |spec|
          next if spec.flags.empty?
          next unless spec.actions.empty?
          label = "#{spec.name})".ljust(8)
          sb << "    #{label}flags=(#{spec.flags.join(' ')}) ;;\n"
        end
      end
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
        lines << "complete -c doma -n '__fish_seen_subcommand_from #{sub}' " \
                 "-a '(command doma tags --names 2>/dev/null)' -d 'tag'"
      end
      lines << ""

      # -t/--tag value completion across the suite.
      lines << "complete -c doma -s t -l tag -x -a '(command doma tags --names 2>/dev/null)' -d 'tag'"
      lines << "complete -c doma -l by -x -a '#{BY_VALUES.join(' ')}' -d 'sort key'"
      lines << "complete -c doma -l ttl -x -a '#{TTL_VALUES.join(' ')}' -d 'duration'"
      lines << ""

      # Action dispatchers (setup, config, trash). Plus the secondary
      # `config get/set/unset` → key dispatcher.
      COMMAND_SPEC.each do |spec|
        next if spec.actions.empty?
        actions_str = spec.actions.join(' ')
        lines << "complete -c doma -n '__fish_seen_subcommand_from #{spec.name}; and not __fish_seen_subcommand_from #{actions_str}' " \
                 "-a '#{actions_str}' -d '#{spec.name} action'"
      end
      lines << "complete -c doma -n '__fish_seen_subcommand_from get set unset' " \
               "-a '#{CONFIG_KEYS.join(' ')}' -d 'config key'"
      lines << ""

      # Per-command long-flag pool. Commands with no long flags (besides
      # --help, which fish handles natively) are silently skipped.
      COMMAND_SPEC.each do |spec|
        long = fish_long_flags(spec.flags)
        next if long.empty?
        long.each do |f|
          name = f.lstrip('-')
          lines << "complete -c doma -n '__fish_seen_subcommand_from #{spec.name}' -l #{name}"
        end
      end

      lines.join("\n") + "\n"
    end
  end
end
