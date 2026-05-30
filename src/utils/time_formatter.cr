require "colorize"

module Doma
  # Shared timestamp formatters for CLI output. Centralizes the
  # absolute and relative-time strings so adding a new command that
  # prints `created_at` / `last_used_at` doesn't reinvent the format
  # — and so any future tweak (locale, precision) lands in one place.
  module TimeFormatter
    extend self

    # ISO-ish local-time format. Stable, sortable, and unambiguous —
    # which `Time#to_s` default isn't (locale-dependent on some libcs).
    #
    # `Time.unix` raises `ArgumentError` for epochs outside the supported
    # year 1–9999 range. Those only arrive via corrupted rows or a
    # hand-crafted import JSON, but a stack trace on display is the wrong
    # failure mode — fall back to a legible marker so one bad row doesn't
    # take down `list`/`info`/`stats`.
    def absolute(epoch : Int64) : String
      Time.unix(epoch).to_local.to_s("%Y-%m-%d %H:%M")
    rescue ArgumentError
      "(invalid date)"
    end

    # Compact "how long ago" using the same `Nu` units the duration
    # parser accepts (`5m`, `3h`, `7d`, `2w`). Past anything ≥ 1 year
    # falls back to `Ny` for readability — the parser doesn't accept
    # `y` but this is display-only. Rendered dim so the absolute
    # timestamp stays the visual anchor.
    def relative_past(epoch : Int64, color : Bool = false) : String
      delta = Time.utc.to_unix - epoch
      text = if delta < 0
               # Clock skew or a timestamp imported from a machine whose
               # clock was ahead leaves `delta` negative; without this guard
               # the first branch prints a nonsensical "-5000s ago". Mirrors
               # `Duration.humanize_remaining`'s "expired" guard. (delta == 0
               # is the just-added present moment — it renders as "0s ago".)
               "just now"
             elsif delta < 60
               "#{delta}s ago"
             elsif delta < 3600
               "#{delta // 60}m ago"
             elsif delta < 86_400
               "#{delta // 3600}h ago"
             elsif delta < 604_800
               "#{delta // 86_400}d ago"
             elsif delta < 31_557_600 # ~365.25d
               "#{delta // 604_800}w ago"
             else
               "#{delta // 31_557_600}y ago"
             end
      color ? text.colorize(:dark_gray).to_s : text
    end
  end
end
