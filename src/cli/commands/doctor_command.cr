require "option_parser"
require "../../db/database"
require "../../utils/config"
require "../../utils/errors"
require "../../utils/logger"

module Doma::CLI
  # Quick install/state sanity check. Reports what doma sees: where it
  # writes, whether the config parses, and how much data is currently
  # tracked. Designed to be the first command users run when something
  # is "off" — and to give us a useful artifact to ask for in bug reports.
  class DoctorCommand
    def run(args : Array(String))
      parser = OptionParser.new do |p|
        p.banner = "Usage: doma doctor"
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
      parser.parse(args)

      report_paths
      report_config
      report_database
    end

    private def report_paths
      section "Paths"
      kv "home", Doma::Config.home
      kv "config", Doma::Config.config_path, present: File.exists?(Doma::Config.config_path)
      kv "database", Doma::Config.db_path, present: File.exists?(Doma::Config.db_path)
    end

    private def report_config
      section "Config"
      path = Doma::Config.config_path
      if !File.exists?(path)
        kv "status", "not present (using defaults)"
        return
      end
      begin
        s = Doma::Settings.load(path)
        kv "status", "ok"
        kv "selector", s.selector.to_s.downcase
        kv "auto_tag.basename", s.auto_tag.basename.to_s
        kv "auto_tag.git", s.auto_tag.git.to_s
      rescue ex : Doma::ConfigError
        kv "status", "INVALID — #{ex.message}"
      end
    end

    private def report_database
      section "Database"
      path = Doma::Config.db_path
      unless File.exists?(path)
        kv "status", "not yet created (will appear after first `doma add`)"
        return
      end

      kv "size", human_size(File.size(path))

      db = Doma::Database.open(path)
      begin
        stats = db.stats(top_n: 0, recent_n: 0)
        kv "directories", stats.total_directories.to_s
        kv "tags", stats.total_tags.to_s
        missing = db.dead_paths.size
        if missing > 0
          kv "missing on disk", "#{missing} (run `doma rm --gone` to prune)"
        end
        kv "schema", "v#{Doma::Snapshot::SCHEMA_VERSION}"
      rescue ex
        kv "status", "READ ERROR — #{ex.message}"
      ensure
        db.close
      end
    end

    private def section(title : String)
      label = Doma::Logger.color_enabled? ? title.colorize(:cyan).bold.to_s : title
      puts ""
      puts label
    end

    private def kv(key : String, value : String, *, present : Bool? = nil)
      marker = case present
               in true  then color_marker("✓", :green)
               in false then color_marker("·", :dark_gray)
               in nil   then "  "
               end
      puts "  #{marker} #{key.ljust(20)} #{value}"
    end

    private def color_marker(glyph : String, color : Symbol) : String
      Doma::Logger.color_enabled? ? glyph.colorize(color).to_s : glyph
    end

    # KB/MB/GB rounding — exact bytes are noisy and the user mostly wants
    # to know "is this thing huge or tiny."
    private def human_size(bytes : Int) : String
      units = %w[B KB MB GB TB]
      n = bytes.to_f
      idx = 0
      while n >= 1024 && idx < units.size - 1
        n /= 1024
        idx += 1
      end
      idx == 0 ? "#{bytes} B" : "#{n.round(1)} #{units[idx]}"
    end
  end
end
