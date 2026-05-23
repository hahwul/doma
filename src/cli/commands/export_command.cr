require "option_parser"
require "../../db/database"
require "../../services/exporter"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/validator"

module Doma::CLI
  class ExportCommand
    def run(args : Array(String))
      format = Doma::Exporter::Format::Json
      output : String? = nil

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma export [--json | --yaml] [-o FILE]"
        p.on("--json", "Output as JSON (default)") { format = Doma::Exporter::Format::Json }
        p.on("--yaml", "Output as YAML") { format = Doma::Exporter::Format::Yaml }
        p.on("-o FILE", "--output=FILE", "Write to FILE instead of stdout") { |f| output = f }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
      end
      parser.parse(args)

      db = Doma::Database.open
      begin
        if raw = output
          path = Doma::Validator.canonicalize(raw)
          validate_output_path!(path)
          write_atomic(db, format, path)
          Doma::Logger.success "exported to #{path}"
        else
          Doma::Exporter.write(db, format, STDOUT)
        end
      ensure
        db.close
      end
    end

    # Catch the obviously-bad output paths up front with a clean
    # ValidationError, so the user gets "output path is a directory"
    # instead of the raw rename/open error the runtime would surface.
    private def validate_output_path!(path : String)
      if Dir.exists?(path)
        raise Doma::ValidationError.new("output path is a directory: #{path}")
      end
      parent = File.dirname(path)
      unless Dir.exists?(parent)
        raise Doma::ValidationError.new("output directory does not exist: #{parent}")
      end
    end

    # Atomic write via temp + rename so a crashed export never leaves a
    # half-written file in place of a previous good snapshot. Translates
    # IO failures into a friendly Doma::Error so the runner's generic
    # rescue (which prints "internal error:") never sees them.
    private def write_atomic(db : Doma::Database, format : Doma::Exporter::Format, path : String)
      tmp = "#{path}.#{Process.pid}.tmp"
      begin
        File.open(tmp, "w") { |f| Doma::Exporter.write(db, format, f) }
        File.rename(tmp, path)
      rescue ex : File::AccessDeniedError | File::Error | IO::Error
        File.delete?(tmp)
        raise Doma::Error.new("export failed: #{ex.message}")
      rescue ex
        File.delete?(tmp)
        raise ex
      end
    end
  end
end
