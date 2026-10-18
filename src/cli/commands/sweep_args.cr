require "../../utils/errors"

module Doma::CLI
  # Argument checks shared by the tag sweeps (`run`, `status`), which
  # take a single tag either positionally or via `-t`, plus `--jobs`.
  module SweepArgs
    def self.flag_tag!(raw : String) : String
      raise Doma::ValidationError.new("tag is empty (-t got an empty value)") if raw.strip.empty?
      raw
    end

    def self.jobs!(raw : String) : Int32
      n = raw.to_i?
      raise Doma::ValidationError.new("--jobs must be a positive integer, got '#{raw}'") if n.nil? || n < 1
      n
    end

    # A glob (`*`, `?`) still matches across several tags, so one tag
    # argument is enough.
    def self.single_tag!(command : String, flag_tags : Array(String), positional : Array(String)) : String?
      if !flag_tags.empty? && !positional.empty?
        raise Doma::ValidationError.new("tag specified both positionally and via -t; pick one")
      end
      if flag_tags.size > 1
        raise Doma::ValidationError.new("#{command} accepts a single tag; got #{flag_tags.size} via -t")
      end
      if positional.size > 1
        raise Doma::ValidationError.new(
          "#{command} accepts a single tag; got #{positional.size} positional args",
          hint: "use a glob like 'work*' to sweep several tags at once"
        )
      end
      flag_tags.first? || positional.first?
    end
  end
end
