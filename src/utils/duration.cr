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

    # Sanity cap for user-supplied TTLs. Anything past this is almost
    # certainly a typo (or shell variable expansion gone wrong) — and
    # without the cap, large inputs would either overflow Int64
    # multiplication or push `expires_at_for` past Crystal's Time range
    # and surface as a generic "internal error".
    MAX_SECONDS = 100_i64 * 365_i64 * 86_400_i64 # ~100 years

    # Returns the input duration converted to seconds.
    def parse_seconds!(raw : String) : Int64
      m = raw.strip.match(PATTERN)
      raise ValidationError.new("invalid duration '#{raw}' (use like 30s, 5m, 1h, 7d, 2w)") unless m
      # `to_i64?` returns nil on overflow rather than raising; a 20-digit
      # number reaches us here just because the regex passed.
      n = m[1].to_i64?
      raise ValidationError.new("duration '#{raw}' is too large (max ~100y)") unless n
      raise ValidationError.new("duration must be positive") if n <= 0
      multiplier = SECONDS_PER_UNIT[m[2].downcase]
      # Guard the multiplication so a value just under Int64::MAX in the
      # input doesn't blow up when scaled by `multiplier`.
      if n > MAX_SECONDS // multiplier
        raise ValidationError.new("duration '#{raw}' is too large (max ~100y)")
      end
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

    # Render the time between now and `expires_at` in the same compact
    # `Nu` form the parser accepts ("3d", "5m", …) so users can tell at
    # a glance what's about to lapse. Past expirations come back as
    # "expired" rather than a negative number.
    def humanize_remaining(expires_at : Int64) : String
      delta = expires_at - Time.utc.to_unix
      return "expired" if delta <= 0
      if delta < 60
        "#{delta}s"
      elsif delta < 3600
        "#{delta // 60}m"
      elsif delta < 86_400
        "#{delta // 3600}h"
      elsif delta < 604_800
        "#{delta // 86_400}d"
      else
        "#{delta // 604_800}w"
      end
    end
  end
end
