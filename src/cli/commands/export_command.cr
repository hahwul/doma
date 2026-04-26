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
          write_atomic(db, format, path)
          Doma::Logger.success "exported to #{path}"
        else
          Doma::Exporter.write(db, format, STDOUT)
        end
      ensure
        db.close
      end
    end

    # Atomic write via temp + rename so a crashed export never leaves a
    # half-written file in place of a previous good snapshot. The rescue
    # guards against leaving the `.tmp` file behind if the write itself
    # fails (disk full, permission error mid-stream, etc.).
    private def write_atomic(db : Doma::Database, format : Doma::Exporter::Format, path : String)
      tmp = "#{path}.#{Process.pid}.tmp"
      begin
        File.open(tmp, "w") { |f| Doma::Exporter.write(db, format, f) }
        File.rename(tmp, path)
      rescue ex
        File.delete(tmp) if File.exists?(tmp)
        raise ex
      end
    end
  end
end
