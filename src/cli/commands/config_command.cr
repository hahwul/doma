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

    SELECTOR_VALUES = %w[auto builtin first]

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
        if suggestion = Doma::Suggester.suggest(action, %w[get set unset list edit path])
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
      effective = effective_value(key)
      puts effective
    end

    private def cmd_set(args : Array(String))
      key = require_arg(args, "key", "doma config set <key> <value>")
      raw = require_arg(args, "value", "doma config set <key> <value>")
      validate_key!(key)
      coerced = coerce(key, raw)

      data = load_yaml
      set_in(data, key, coerced)
      write_yaml(data)
      Doma::Logger.success "set #{key} = #{render(coerced)}"
    end

    private def cmd_unset(args : Array(String))
      key = require_arg(args, "key", "doma config unset <key>")
      validate_key!(key)
      data = load_yaml
      removed = unset_in(data, key)
      if removed
        write_yaml(data)
        Doma::Logger.success "unset #{key}"
      else
        Doma::Logger.info "#{key} was not set (already default)"
      end
    end

    private def cmd_list(args : Array(String))
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma config list"
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end

      data = load_yaml
      width = KEYS.max_of(&.size)
      KEYS.each do |key|
        source = key_present?(data, key) ? "file" : "default"
        marker = source == "file" ? "*" : " "
        value = effective_value(key)
        value = "(empty)" if value.empty?
        puts "#{marker} #{key.ljust(width)}  #{value.ljust(8)}  (#{source})"
      end
      puts ""
      puts "* = customized (from #{Doma::Config.config_path})"
    end

    private def cmd_edit(args : Array(String))
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma config edit"
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end

      Doma::Config.ensure_home!
      path = Doma::Config.config_path
      # Seed an empty file so $EDITOR doesn't open a non-existent path
      # (Vim/etc handle it, but seeding makes intent obvious).
      File.write(path, "") unless File.exists?(path)

      editor = ENV["VISUAL"]? || ENV["EDITOR"]?
      if editor.nil? || editor.strip.empty?
        raise Doma::ConfigError.new(
          "no editor configured: set $VISUAL or $EDITOR (e.g. `export EDITOR=nano`)"
        )
      end
      status = Process.run(editor, [path], shell: true, input: STDIN, output: STDOUT, error: STDERR)
      exit(status.exit_code) unless status.success?

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
      OptionParser.parse(args) do |p|
        p.banner = "Usage: doma config path"
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
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
    # We return YAML::Any so writing-back produces the right scalar shape.
    private def coerce(key : String, raw : String) : YAML::Any
      case key
      when "db_path"
        if raw.blank?
          raise Doma::ValidationError.new(
            "db_path cannot be empty",
            "use `doma config unset db_path` to revert to the default"
          )
        end
        YAML::Any.new(raw)
      when "selector"
        v = raw.downcase
        unless SELECTOR_VALUES.includes?(v)
          raise Doma::ValidationError.new(
            "invalid value for selector: '#{raw}'",
            "allowed: #{SELECTOR_VALUES.join(", ")}"
          )
        end
        YAML::Any.new(v)
      when "auto_tag.basename", "auto_tag.git"
        YAML::Any.new(parse_bool(key, raw))
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

    private def render(value : YAML::Any) : String
      case raw = value.raw
      when Bool, String, Int, Float
        raw.to_s
      when Nil
        "(unset)"
      else
        value.to_yaml.strip
      end
    end

    # ------------------------------------------------------------------
    # YAML I/O
    # ------------------------------------------------------------------

    # The on-disk shape is a plain map; we work with String-keyed hashes
    # so the dotted-path code stays readable. YAML::Any is converted at
    # the boundary.
    alias YamlMap = Hash(String, YAML::Any)

    private def load_yaml : YamlMap
      path = Doma::Config.config_path
      return YamlMap.new unless File.exists?(path)
      content = File.read(path)
      return YamlMap.new if content.strip.empty?
      parsed = YAML.parse(content)
      to_string_map(parsed)
    rescue ex : YAML::ParseException
      raise Doma::ConfigError.new("invalid config (#{Doma::Config.config_path}): #{ex.message}")
    end

    private def to_string_map(any : YAML::Any) : YamlMap
      raw = any.raw
      return YamlMap.new if raw.nil?
      unless raw.is_a?(Hash)
        raise Doma::ConfigError.new("config must be a YAML mapping, got #{raw.class}")
      end
      out = YamlMap.new
      raw.each do |k, v|
        out[k.as_s] = v
      end
      out
    end

    private def write_yaml(data : YamlMap)
      Doma::Config.ensure_home!
      path = Doma::Config.config_path
      yaml = wrap_map(data).to_yaml
      # Write atomically so a crash mid-write doesn't truncate the file.
      tmp = "#{path}.tmp"
      File.write(tmp, yaml)
      File.rename(tmp, path)
      # Invalidate the memoized Settings so subsequent calls see the new
      # values (relevant for tests and for `set` immediately followed by
      # `get`).
      Doma::Settings.current = nil
    end

    # ------------------------------------------------------------------
    # Dotted-path helpers
    # ------------------------------------------------------------------

    private def set_in(data : YamlMap, key : String, value : YAML::Any)
      parts = key.split('.')
      if parts.size == 1
        data[parts.first] = value
        return
      end
      head, *rest = parts
      child = as_yaml_map(data[head]?) || YamlMap.new
      set_in(child, rest.join('.'), value)
      data[head] = wrap_map(child)
    end

    private def unset_in(data : YamlMap, key : String) : Bool
      parts = key.split('.')
      if parts.size == 1
        return data.delete(parts.first) ? true : false
      end
      head, *rest = parts
      child = as_yaml_map(data[head]?)
      return false if child.nil?
      removed = unset_in(child, rest.join('.'))
      if removed
        if child.empty?
          data.delete(head)
        else
          data[head] = wrap_map(child)
        end
      end
      removed
    end

    private def wrap_map(map : YamlMap) : YAML::Any
      hash = Hash(YAML::Any, YAML::Any).new
      map.each { |k, v| hash[YAML::Any.new(k)] = v }
      YAML::Any.new(hash)
    end

    # Coerce a YAML::Any node into a YamlMap copy, or nil if the node
    # is missing or not a mapping. The copy keeps the dotted-path
    # helpers working on String-keyed hashes without mutating the
    # original tree until we re-`wrap_map` it on the way back up.
    private def as_yaml_map(any : YAML::Any?) : YamlMap?
      return if any.nil?
      raw = any.raw
      return unless raw.is_a?(Hash)
      m = YamlMap.new
      raw.each { |k, v| m[k.as_s] = v }
      m
    end

    private def key_present?(data : YamlMap, key : String) : Bool
      parts = key.split('.')
      cur = data
      parts[0...-1].each do |part|
        child = as_yaml_map(cur[part]?)
        return false if child.nil?
        cur = child
      end
      cur.has_key?(parts.last)
    end

    # ------------------------------------------------------------------
    # Effective values (after defaults)
    # ------------------------------------------------------------------

    private def effective_value(key : String) : String
      # Hit the file fresh — Settings.current may be cached from before
      # the most recent set.
      Doma::Settings.current = nil
      s = Doma::Settings.current
      case key
      when "db_path"
        s.db_path || ""
      when "selector"
        s.selector.to_s.downcase
      when "auto_tag.basename"
        s.auto_tag.basename.to_s
      when "auto_tag.git"
        s.auto_tag.git.to_s
      else
        ""
      end
    end

    # ------------------------------------------------------------------
    # Misc
    # ------------------------------------------------------------------

    private def require_arg(args : Array(String), name : String, usage : String) : String
      v = args.shift?
      if v.nil?
        raise Doma::ValidationError.new("missing #{name}", "Usage: #{usage}")
      end
      v
    end
  end
end
