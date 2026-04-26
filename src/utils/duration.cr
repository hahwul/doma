require "./errors"

module Doma
  # Tiny duration parser for TTL flags. Accepts a single number+unit
  # combo (`30s`, `5m`, `1h`, `7d`, `2w`) — keeping the format strict
  # avoids the ambiguity of compound spec ("1d2h") and matches what
  # users type in flag form.
  module Duration
    extend self

    PATTERN = /\A(\d+)([smhdw])\z/i

    SECONDS_PER_UNIT = {
      "s" => 1_i64,
      "m" => 60_i64,
      "h" => 3600_i64,
      "d" => 86_400_i64,
      "w" => 604_800_i64,
    }

    # Returns the input duration converted to seconds.
    def parse_seconds!(raw : String) : Int64
      m = raw.strip.match(PATTERN)
      raise ValidationError.new("invalid duration '#{raw}' (use like 30s, 5m, 1h, 7d, 2w)") unless m
      n = m[1].to_i64
      raise ValidationError.new("duration must be positive") if n <= 0
      multiplier = SECONDS_PER_UNIT[m[2].downcase]
      n * multiplier
    end

    # Returns `now + duration` as a unix epoch suitable for the
    # `expires_at` column — pre-computed so the call site doesn't need
    # to redo the time arithmetic.
    def expires_at_for(raw : String) : Int64
      Time.utc.to_unix + parse_seconds!(raw)
    end

    # Sensible default for `--tmp`: a working week.
    DEFAULT_TMP_SECONDS = 7 * 86_400_i64

    def default_tmp_expires_at : Int64
      Time.utc.to_unix + DEFAULT_TMP_SECONDS
    end
  end
end
