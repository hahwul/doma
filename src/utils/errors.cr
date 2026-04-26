module Doma
  # Base class for all expected, user-facing errors. The CLI runner catches
  # these and prints them in the standard `Error: ...` form (no stack trace).
  # Anything that escapes the boundary as a non-Doma::Error is treated as a
  # bug and shown verbatim.
  class Error < Exception
    getter exit_code : Int32
    getter hint : String?

    def initialize(message : String, @exit_code : Int32 = 1, @hint : String? = nil)
      super(message)
    end
  end

  class ValidationError < Error
    def initialize(message : String, hint : String? = nil)
      super(message, 2, hint)
    end
  end

  class NotFoundError < Error
    def initialize(message : String, hint : String? = nil)
      super(message, 3, hint)
    end
  end

  class ConflictError < Error
    def initialize(message : String)
      super(message, 4)
    end
  end

  class ConfigError < Error
    def initialize(message : String)
      super(message, 5)
    end
  end

  class ImportError < Error
    def initialize(message : String)
      super(message, 6)
    end
  end
end
