require "file_utils"
require "yaml"
require "./errors"
require "./validator"

module Doma
  # Static path helpers (env-aware). The `Settings` struct below holds the
  # parsed user config (~/.config/doma/config.yml).
  module Config
    extend self

    DEFAULT_DIR = "~/.config/doma"

    # `home: true` is what teaches `File.expand_path` to actually substitute
    # `~` for `$HOME`. Without it, `~/.config/doma` is taken literally and
    # creates a `~` directory inside the cwd — a real bug we shipped earlier.
    #
    # `.presence` treats a set-but-blank `DOMA_HOME=""` as unset: without it
    # the empty string is truthy and `File.expand_path("")` resolves to the
    # cwd, silently scattering the db/config into whatever directory the
    # command happened to run from. Same guard `db_path` already carries.
    def home : String
      Validator.expand_home(ENV["DOMA_HOME"]?.presence || DEFAULT_DIR)
    end

    def config_path : String
      # Blank `DOMA_CONFIG=""` is treated as unset (see `home`); otherwise it
      # would resolve to the cwd and be used as the config *file* path.
      explicit = ENV["DOMA_CONFIG"]?.presence
      return Validator.expand_home(explicit) if explicit
      File.join(home, "config.yml")
    end

    def db_path : String
      # A blank value on either source (`DOMA_DB=""`, `db_path: ""` in
      # config.yml, or `config set db_path ""`) used to be truthy and
      # resolve to the cwd via `File.expand_path("")`, breaking every
      # subsequent command with "DOMA_DB points at a directory". Treat
      # blanks as unset on both sources.
      explicit = ENV["DOMA_DB"]?.presence || Settings.current.db_path.try(&.presence)
      return Validator.expand_home(explicit) if explicit
      File.join(home, "doma.db")
    end

    # Make sure the home directory exists, translating the common
    # misconfiguration ("$DOMA_HOME points at a regular file") into a
    # ConfigError with a clear message instead of letting the
    # `mkdir_p`'s raw "Unable to create directory" leak as an internal
    # error.
    def ensure_home!
      target = home
      if File.file?(target)
        raise ConfigError.new(
          "DOMA_HOME points at a file, not a directory: #{target}"
        )
      end
      FileUtils.mkdir_p(target)
    rescue ex : ConfigError
      raise ex
    rescue ex
      raise ConfigError.new("cannot create DOMA_HOME (#{target}): #{ex.message}")
    end
  end

  # Persisted user preferences. Values are nil when unset so the loader can
  # tell "user explicitly chose this" from "fall back to built-in default".
  class Settings
    include YAML::Serializable
    include YAML::Serializable::Strict

    enum SelectorMode
      Auto    # interactive picker if STDIN is a TTY, else first
      Builtin # force the interactive picker
      First   # always pick the first match (scriptable)
    end

    @[YAML::Field(key: "db_path")]
    property db_path : String? = nil

    @[YAML::Field(key: "selector")]
    property selector : SelectorMode = SelectorMode::Auto

    @[YAML::Field(key: "auto_tag")]
    property auto_tag : AutoTag = AutoTag.new

    class AutoTag
      include YAML::Serializable
      include YAML::Serializable::Strict

      @[YAML::Field(key: "basename")]
      property basename : Bool = false

      @[YAML::Field(key: "git")]
      property git : Bool = false

      def initialize
      end
    end

    def initialize
    end

    @@current : Settings? = nil

    def self.current : Settings
      @@current ||= load(Doma::Config.config_path)
    end

    # Test/spec hook. Pass nil to fall back to disk lookup again.
    def self.current=(value : Settings?)
      @@current = value
    end

    def self.load(path : String) : Settings
      return new unless File.exists?(path)
      content = File.read(path)
      return new if content.strip.empty?
      from_yaml(content)
    rescue ex : YAML::ParseException
      raise ConfigError.new(format_parse_error(path, ex))
    end

    # Wrap the raw YAML parser message in something a user can act on.
    # The library message already includes `at line N, column M`, but
    # "Unknown yaml attribute" reads as jargon — translate to plain
    # English and append the list of valid keys so the user can self-fix.
    private def self.format_parse_error(path : String, ex : YAML::ParseException) : String
      raw = ex.message || ex.class.name
      location = "line #{ex.line_number}"
      location += ", column #{ex.column_number}" if ex.column_number > 0

      detail =
        case raw
        when /Unknown yaml attribute: (\S+)/
          key = $1
          "unknown key '#{key}' (known: #{VALID_KEYS.join(", ")})"
        when /Unknown enum (?:[\w:]+::)?(\w+) value: "([^"]+)"/
          short_name = $1
          value = $2
          allowed = ENUM_VALUES[short_name]?
          allowed ? "invalid value '#{value}' (allowed: #{allowed.join(", ")})" : "invalid enum value '#{value}'"
        when /Expected (\w+), not (\w+)/
          "expected #{$1}, got #{$2}"
        else
          raw
        end

      "invalid config (#{path}, #{location}): #{detail}"
    end

    # Keep these aligned with the @[YAML::Field] declarations above —
    # surfaced in error messages so users can self-correct typos in their
    # config without grepping source.
    VALID_KEYS  = %w[db_path selector auto_tag]
    ENUM_VALUES = {
      "SelectorMode" => %w[auto builtin first],
    }
  end
end
