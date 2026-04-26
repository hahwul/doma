require "option_parser"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/validator"

module Doma::CLI
  class RmCommand
    def run(args : Array(String))
      tags = [] of String
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma rm <path> [-t TAG ...]"
        p.on("-t TAG", "--tag=TAG", "Remove this tag (repeatable, comma-separated allowed)") do |t|
          t.split(',').each { |x| tags << x.strip unless x.strip.empty? }
        end
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args do |before, after|
          positional.concat(before)
          positional.concat(after)
        end
      end
      parser.parse(args)

      raise Doma::ValidationError.new("path is required") if positional.empty?

      db = Doma::Database.open
      begin
        positional.each do |path|
          if tags.empty?
            if db.remove_path(path)
              Doma::Logger.success "removed #{Doma::Validator.canonicalize(path)}"
            else
              Doma::Logger.warn "not registered: #{path}"
            end
          else
            if db.remove_tags(path, tags)
              Doma::Logger.success "untagged #{Doma::Validator.canonicalize(path)} (#{tags.join(", ")})"
            else
              Doma::Logger.warn "not registered: #{path}"
            end
          end
        end
      ensure
        db.close
      end
    end
  end
end
