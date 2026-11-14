require "termisu"

module Doma
  module TUI
    # Terminal-text helpers for the finder: display width, tail fitting, and
    # control-byte scrubbing. Pure (no terminal handle), so specs cover them.
    module Text
      extend self

      # Terminal columns `text` occupies (CJK/Hangul take two, combining
      # marks none) — `String#size` counts codepoints, which wraps rows.
      def display_width(text : String) : Int32
        text.each_char.sum { |c| char_width(c) }
      end

      def char_width(c : Char) : Int32
        Termisu::UnicodeWidth.codepoint_width(c.ord).to_i
      end

      # The longest suffix of `text` that fits in `room` columns, so the end
      # being typed (and the cursor after it) stays visible.
      def tail_fit(text : String, room : Int) : String
        chars = text.chars
        col = 0
        i = chars.size
        while i > 0
          w = char_width(chars[i - 1])
          break if col + w > room
          col += w
          i -= 1
        end
        chars[i..].join
      end

      # Strip ANSI control bytes before text reaches the terminal. Paths come
      # from anywhere on disk and aren't validated against control
      # characters, so a path containing `\e` could otherwise inject
      # color/cursor sequences and spoof which entry is selected. Each control
      # byte becomes `?` so the row stays recognizable. Tab (0x09) passes
      # through — terminals render it as a gap, not an injection.
      def sanitize(text : String) : String
        return text unless text.each_char.any? { |c| control_byte?(c) }
        text.gsub { |c| control_byte?(c) ? '?' : c }
      end

      private def control_byte?(c : Char) : Bool
        ord = c.ord
        (ord < 0x20 && ord != 0x09) || ord == 0x7f
      end

      # Any non-control codepoint counts as query input — `Char#printable?`
      # is ASCII-only, and Korean etc. must be typeable.
      def printable?(c : Char) : Bool
        ord = c.ord
        ord >= 0x20 && ord != 0x7f
      end
    end
  end
end
