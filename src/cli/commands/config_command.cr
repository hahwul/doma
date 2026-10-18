require "option_parser"
require "yaml"
require "../../utils/config"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/suggester"

module Doma::CLI
  # `doma config <get|set|unset|list|edit|path>` — surface the
  # ~/.config/doma/config.yml settings to the CLI so users don't have to
  # grep the source for available keys or hand-edit YAML.
  class ConfigCommand
    # Schema-light registry. Each entry knows how to coerce a string value
    # to its target type and how to render the current value back out.
    # Keeping this explicit (rather than reflective) makes the allow-list
    # for `set` obvious at a glance.
    KEYS = [
      "db_path",
      "selector",
      "auto_tag.basename",
      "auto_tag.git",
    ]

    # Also referenced by `setup completion`, so the action list in the
    # generated completion scripts can't drift from the dispatcher below.
    ACTIONS = %w[get set unset list edit path]

    # Derived from the enum so a new mode is accepted by `config set`
    # the moment it exists.
    SELECTOR_VALUES = Doma::Settings::SelectorMode.values.map(&.to_s.downcase)

    def run(args : Array(String))
      action = args.shift?
      case action
      when nil, "-h", "--help", "help"
        print_help
      when "get"
        cmd_get(args)
      when "set"
        cmd_set(args)
      when "unset"
        cmd_unset(args)
      when "list", "ls"
        cmd_list(args)
      when "edit"
        cmd_edit(args)
      when "path"
        cmd_path(args)
      else
        Doma::Logger.error "unknown config action '#{action}'"
        if suggestion = Doma::Suggester.suggest(action, ACTIONS)
          STDERR.puts "  Did you mean '#{suggestion}'?"
        end
        STDERR.puts "Run 'doma config --help' to see actions."
        exit 1
      end
    end

    private def print_help
      puts "Usage: doma config <action> [args]"
      puts ""
      puts "Actions:"
      puts "  get <key>            Print current value (default if unset)"
      puts "  set <key> <value>    Persist value to config.yml"
      puts "  unset <key>          Remove the key (revert to default)"
      puts "  list                 Show all settings with source (default/file)"
      puts "  edit                 Open config.yml in $EDITOR / $VISUAL"
      puts "  path                 Print the resolved config path"
      puts ""
      puts "Keys:"
      KEYS.each { |k| puts "  #{k}" }
      puts ""
      puts "Note: `set`/`unset` rewrite config.yml and do not preserve"
      puts "comments. Use `doma config edit` for hand-edits with comments."
    end

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    private def cmd_get(args : Array(String))
      key = require_arg(args, "key", "doma config get <key>")
      validate_key!(key)
      puts effective_value(load_file, key)
    end

    private def cmd_set(args : Array(String))
      key = require_arg(args, "key", "doma config set <key> <value>")
      raw = require_arg(args, "value", "doma config set <key> <value>")
      validate_key!(key)
      coerced = coerce(key, raw)

      settings, _ = load_for_write(key)
      settings[key] = coerced
      write_file(settings)
      Doma::Logger.success "set #{key} = #{coerced}"
    end

    private def cmd_unset(args : Array(String))
      key = require_arg(args, "key", "doma config unset <key>")
      validate_key!(key)
      settings, repaired = load_for_write(key)
      if settings[key].nil? && !repaired
        Doma::Logger.info "#{key} was not set (already default)"
      else
        settings[key] = nil
        write_file(settings)
        Doma::Logger.success "unset #{key}"
      end
    end

    private def cmd_list(args : Array(String))
      parse_no_flags(args, "Usage: doma config list")

      settings = load_file
      width = KEYS.max_of(&.size)
      KEYS.each do |key|
        source = settings[key].nil? ? "default" : "file"
        marker = source == "file" ? "*" : " "
        value = effective_value(settings, key)
        value = "(empty)" if value.empty?
        puts "#{marker} #{key.ljust(width)}  #{value.ljust(8)}  (#{source})"
      end
      puts ""
      puts "* = customized (from #{Doma::Config.config_path})"
    end

    private def cmd_edit(args : Array(String))
      parse_no_flags(args, "Usage: doma config edit")

      Doma::Config.ensure_home!
      path = Doma::Config.config_path
      # Seed an empty file so $EDITOR doesn't open a non-existent path
      # (Vim/etc handle it, but seeding makes intent obvious).
      unless File.exists?(path)
        Dir.mkdir_p(File.dirname(path))
        File.write(path, "")
      end

      editor = ENV["VISUAL"]? || ENV["EDITOR"]?
      if editor.nil? || editor.strip.empty?
        raise Doma::ConfigError.new(
          "no editor configured: set $VISUAL or $EDITOR (e.g. `export EDITOR=nano`)"
        )
      end
      status = Process.run(editor, [path], shell: true, input: STDIN, output: STDOUT, error: STDERR)
      exit(status.exit_code? || 128 + (status.exit_signal?.try(&.value) || 0)) unless status.success?

      # Validate the post-edit file so users learn about syntax errors
      # immediately instead of on the next `doma <cmd>`.
      begin
        Doma::Settings.load(path)
        Doma::Logger.success "saved #{path}"
      rescue ex : Doma::ConfigError
        Doma::Logger.error ex.message || "invalid config"
        STDERR.puts "  Run `doma config edit` again to fix."
        exit 5
      end
    end

    private def cmd_path(args : Array(String))
      parse_no_flags(args, "Usage: doma config path")
      puts Doma::Config.config_path
    end

    # ------------------------------------------------------------------
    # Validation / coercion
    # ------------------------------------------------------------------

    private def validate_key!(key : String)
      return if KEYS.includes?(key)
      hint = if suggestion = Doma::Suggester.suggest(key, KEYS)
               "did you mean '#{suggestion}'?"
             else
               "valid keys: #{KEYS.join(", ")}"
             end
      raise Doma::ValidationError.new("unknown config key '#{key}'", hint)
    end

    # Coerce a raw CLI string into the value type the schema expects.
    private def coerce(key : String, raw : String) : String | Bool
      case key
      when "db_path"
        if raw.blank?
          raise Doma::ValidationError.new(
            "db_path cannot be empty",
            "use `doma config unset db_path` to revert to the default"
          )
        end
        raw
      when "selector"
        v = raw.downcase
        unless SELECTOR_VALUES.includes?(v)
          raise Doma::ValidationError.new(
            "invalid value for selector: '#{raw}'",
            "allowed: #{SELECTOR_VALUES.join(", ")}"
          )
        end
        v
      when "auto_tag.basename", "auto_tag.git"
        parse_bool(key, raw)
      else
        raise Doma::ValidationError.new("unsupported key '#{key}'")
      end
    end

    private def parse_bool(key : String, raw : String) : Bool
      case raw.downcase
      when "true", "yes", "y", "1", "on"  then true
      when "false", "no", "n", "0", "off" then false
      else
        raise Doma::ValidationError.new(
          "invalid bool for #{key}: '#{raw}'",
          "allowed: true, false (also yes/no, on/off, 1/0)"
        )
      end
    end

    # ------------------------------------------------------------------
    # File I/O
    # ------------------------------------------------------------------

    # Read the file fresh — `Settings.current` may be cached from before
    # the most recent set. `Settings.load` raises the same ConfigError
    # shapes every other command sees for a malformed file.
    private def load_file : Doma::Settings
      Doma::Settings.load(Doma::Config.config_path)
    end

    # `set`/`unset` must be able to fix the very key that breaks the
    # strict load (`selector: bogus`), so on failure retry with that key
    # dropped. Returns whether that repair happened; any other breakage
    # re-raises the original error.
    private def load_for_write(key : String) : {Doma::Settings, Bool}
      {load_file, false}
    rescue ex : Doma::ConfigError
      begin
        root = YAML.parse(File.read(Doma::Config.config_path)).as_h
        head, _, tail = key.partition('.')
        parent = tail.empty? ? root : root[YAML::Any.new(head)]?.try(&.as_h?)
        raise ex unless parent && parent.delete(YAML::Any.new(tail.empty? ? head : tail))
        {Doma::Settings.from_yaml(root.to_yaml), true}
      rescue
        raise ex
      end
    end

    private def write_file(settings : Doma::Settings)
      Doma::Config.ensure_home!
      path = Doma::Config.config_path
      # Write through a symlinked config (dotfiles) instead of replacing
      # the link, and make sure a custom DOMA_CONFIG's directory exists.
      path = File.realpath(path) if File.symlink?(path) && File.exists?(path)
      Dir.mkdir_p(File.dirname(path))
      # Write atomically so a crash mid-write doesn't truncate the file.
      tmp = "#{path}.tmp"
      File.write(tmp, settings.to_yaml)
      File.rename(tmp, path)
      # Invalidate the memoized Settings so later reads see the new values.
      Doma::Settings.current = nil
    end

    private def effective_value(settings : Doma::Settings, key : String) : String
      case key
      when "db_path"           then settings.db_path || ""
      when "selector"          then settings.selector.to_s.downcase
      when "auto_tag.basename" then settings.auto_tag.basename.to_s
      when "auto_tag.git"      then settings.auto_tag.git.to_s
      else                          ""
      end
    end

    # ------------------------------------------------------------------
    # Misc
    # ------------------------------------------------------------------

    # The flagless actions still reject unknown options (OptionParser
    # raises) and answer `-h`.
    private def parse_no_flags(args : Array(String), banner : String)
      OptionParser.parse(args) do |p|
        p.banner = banner
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
    end

    private def require_arg(args : Array(String), name : String, usage : String) : String
      v = args.shift?
      if v.nil?
        raise Doma::ValidationError.new("missing #{name}", "Usage: #{usage}")
      end
      v
    end
  end
end
