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
      json_set = false
      yaml_set = false
      portable = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma export [--json | --yaml] [--portable] [-o FILE]"
        p.on("--json", "Output as JSON (default)") { format = Doma::Exporter::Format::Json; json_set = true }
        p.on("--yaml", "Output as YAML") { format = Doma::Exporter::Format::Yaml; yaml_set = true }
        p.on("--portable", "For another machine: ~/-relative paths, plus each repo's origin URL for `import --clone`") { portable = true }
        p.on("-o FILE", "--output=FILE", "Write to FILE instead of stdout") { |f| output = f }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        # `doma export FILE` (mirroring `import FILE`) used to drop FILE
        # and dump to stdout with exit 0 — a backup that was never written.
        p.unknown_args do |before, after|
          stray = before + after
          unless stray.empty?
            raise Doma::ValidationError.new("unexpected argument '#{stray.first}' (use -o FILE to write to a file)")
          end
        end
      end
      parser.parse(args)

      # --json and --yaml are two output formats; with both set the later
      # flag silently won and the other was dropped. Reject the combination,
      # mirroring `list` and `tags`'s mutually-exclusive output formats so a
      # script that expected YAML can't quietly receive JSON instead.
      if json_set && yaml_set
        raise Doma::ValidationError.new(
          "--json and --yaml are mutually exclusive (pick one output format)"
        )
      end

      Doma::Database.open do |db|
        if raw = output
          path = Doma::Validator.canonicalize(raw)
          validate_output_path!(path)
          if File.exists?(path) && !File.file?(path)
            # A device or pipe (`-o /dev/stdout`) can't take a temp file
            # beside it or be renamed over: write straight through, and
            # keep the success line out of what may be the data stream.
            io_error { File.open(path, "w") { |f| Doma::Exporter.write(db, format, f, portable) } }
          else
            write_atomic(db, format, path, portable)
            Doma::Logger.success "exported to #{path}"
          end
        else
          Doma::Exporter.write(db, format, STDOUT, portable)
        end
      end
    end

    # Catch the obviously-bad output paths up front with a clean
    # ValidationError, so the user gets "output path is a directory"
    # instead of the raw rename/open error the runtime would surface.
    private def validate_output_path!(path : String)
      if Doma::Validator.directory?(path)
        raise Doma::ValidationError.new("output path is a directory: #{path}")
      end
      parent = File.dirname(path)
      unless Doma::Validator.directory?(parent)
        raise Doma::ValidationError.new("output directory does not exist: #{parent}")
      end

      database = Doma::Validator.canonicalize(Doma::Config.db_path)
      output_info = File.info?(path)
      # Compare the files too, since a case-insensitive filesystem can
      # resolve a differently spelled path to the same database file.
      {database, "#{database}-wal", "#{database}-shm", "#{database}-journal"}.each do |protected_path|
        if path == protected_path || (output_info && File.info?(protected_path).try(&.same_file?(output_info)))
          raise Doma::ValidationError.new("output path overlaps the active database: #{path}")
        end
      end
    end

    # Atomic write via temp + rename so a crashed export never leaves a
    # half-written file in place of a previous good snapshot.
    private def write_atomic(db : Doma::Database, format : Doma::Exporter::Format, path : String, portable : Bool)
      tmp = "#{path}.#{Process.pid}.tmp"
      io_error do
        File.open(tmp, "w") { |f| Doma::Exporter.write(db, format, f, portable) }
        File.rename(tmp, path)
      ensure
        File.delete?(tmp)
      end
    end

    # Translates IO failures into a friendly Doma::Error so the runner's
    # generic rescue (which prints "internal error:") never sees them.
    private def io_error(&)
      yield
    rescue ex : IO::Error
      raise Doma::Error.new("export failed: #{ex.message}")
    end
  end
end
