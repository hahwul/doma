require "option_parser"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"

module Doma::CLI
  # Renames or merges a tag. If the new tag already exists, every directory
  # carrying the old tag is re-tagged with the new one and the old tag is
  # removed. The whole operation is transactional.
  class RenameCommand
    def run(args : Array(String))
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma rename <old-tag> <new-tag>"
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

      if positional.size != 2
        raise Doma::ValidationError.new("expected exactly two arguments: <old-tag> <new-tag>")
      end

      old_name, new_name = positional[0], positional[1]
      db = Doma::Database.open
      begin
        case db.rename_tag(old_name, new_name)
        when :noop
          Doma::Logger.info "no change (#{old_name} == #{new_name})"
        when :renamed
          Doma::Logger.success "renamed #{old_name} -> #{new_name}"
        when :merged
          Doma::Logger.success "merged #{old_name} into existing #{new_name}"
        end
      ensure
        db.close
      end
    end
  end
end
