module Doma
  # In-process interactive picker. Replaces the fzf shell-out with a
  # Crystal-native termios + ANSI implementation so doma keeps the "single
  # binary, no external runtime deps" promise.
  #
  # Reads from /dev/tty directly so it works regardless of stdin/stdout
  # piping (the caller can still capture the picked value on stdout — the
  # picker's UI lives entirely on /dev/tty).
  #
  # Filter is a case-insensitive substring match across the visible label
  # and an optional hint. That's deliberately simpler than fzf's fuzzy
  # matching: it's what users overwhelmingly want for the doma corpus
  # (a few hundred paths/tags), it's predictable, and it has no scoring
  # surface area to argue about.
  module Picker
    extend self

    record Item, value : String, label : String, hint : String? = nil
    record Result, value : String? = nil, cancelled : Bool = false

    DEFAULT_VIEWPORT_ROWS = 12

    # POSIX-defined positions in `Termios::c_cc` for the read-min and
    # read-timeout slots. Crystal's stdlib doesn't expose these as named
    # constants on macOS, but the values are identical across BSD and
    # glibc, so hard-coding is portable.
    VMIN  = 16
    VTIME = 17

    # Public entry point. Returns immediately for empty / single-item
    # input without touching the terminal.
    def pick(items : Array(Item), prompt : String) : Result
      return Result.new(cancelled: true) if items.empty?
      return Result.new(value: items.first.value) if items.size == 1
      return Result.new(cancelled: true) unless STDIN.tty?

      tty = open_tty
      return Result.new(cancelled: true) unless tty

      begin
        Session.new(items, prompt, tty).run
      ensure
        tty.close
      end
    end

    # Filter logic exposed for testing without a TTY.
    def filter(items : Array(Item), query : String) : Array(Item)
      return items if query.empty?
      q = query.downcase
      items.select do |it|
        it.label.downcase.includes?(q) ||
          it.hint.try(&.downcase.includes?(q))
      end
    end

    private def open_tty : IO::FileDescriptor?
      File.open("/dev/tty", "r+")
    rescue
      nil
    end

    # One run of the picker. Owns terminal state; restores on every exit
    # path (including exception) via the `ensure` in `with_raw_mode`.
    private class Session
      @query : String = ""
      @cursor : Int32 = 0
      @offset : Int32 = 0
      @rows : Int32 = DEFAULT_VIEWPORT_ROWS
      @width : Int32 = 100

      def initialize(@items : Array(Item), @prompt : String, @tty : IO::FileDescriptor)
        @width = (ENV["COLUMNS"]?.try(&.to_i?) || 100).clamp(20, 240)
      end

      def run : Result
        result : Result = Result.new(cancelled: true)
        with_raw_mode do
          # Reserve render area below the prompt line so we don't smear
          # over whatever was on screen before.
          (@rows + 1).times { @tty.print('\n') }
          @tty.print("\e[#{@rows + 1}A")

          loop do
            render
            case action = read_action
            when :up        then move(-1)
            when :down      then move(+1)
            when :page_up   then move(-@rows)
            when :page_down then move(+@rows)
            when :enter
              filtered = Picker.filter(@items, @query)
              if pick = filtered[@cursor]?
                cleanup
                result = Result.new(value: pick.value)
                break
              end
            when :cancel
              cleanup
              result = Result.new(cancelled: true)
              break
            when :backspace
              unless @query.empty?
                @query = @query[0...-1]
                @cursor = 0
                @offset = 0
              end
            else
              if action.is_a?(Char) && printable?(action)
                @query += action.to_s
                @cursor = 0
                @offset = 0
              end
            end
          end
        end
        result
      end

      # ---------- Render ----------

      private def render
        filtered = Picker.filter(@items, @query)
        # Keep cursor inside bounds when the filter shrinks the list.
        @cursor = filtered.size - 1 if @cursor >= filtered.size && filtered.size > 0
        @cursor = 0 if filtered.empty?
        @offset = @cursor if @offset > @cursor
        @offset = @cursor - @rows + 1 if @cursor - @offset >= @rows
        @offset = 0 if @offset < 0

        io = String::Builder.new
        # Move to the top of our render area, clear from there to end of
        # screen — single redraw avoids flicker without diff machinery.
        io << "\e[" << (@rows + 1) << "A\r\e[J"

        count_label = "#{filtered.size}/#{@items.size}"
        io << "\e[1;36m" << @prompt << "›\e[0m " << @query
        io << "  \e[2m" << count_label << "\e[0m\n"

        end_idx = Math.min(@offset + @rows, filtered.size)
        rendered = 0
        (@offset...end_idx).each do |i|
          item = filtered[i]
          if i == @cursor
            io << "\e[7m▌ "
            io << render_line(item)
            io << "\e[0m\n"
          else
            io << "  "
            io << render_line(item)
            io << "\n"
          end
          rendered += 1
        end
        # Pad blank lines so the area stays the same height as the user
        # filters down — otherwise prior items leave artifacts.
        (@rows - rendered).times { io << "\n" }

        @tty.print(io.to_s)
        @tty.flush
      end

      # path-style label on the left, optional gray hint on the right,
      # truncated to fit terminal width.
      private def render_line(item : Item) : String
        label = item.label
        hint = item.hint
        if hint.nil? || hint.empty?
          truncate(label, @width - 4)
        else
          # Reserve roughly a third for the hint, two-thirds for the label.
          hint_room = (@width // 3).clamp(12, 80)
          label_room = @width - hint_room - 6
          "#{truncate(label, label_room).ljust(label_room)}  \e[2m#{truncate(hint, hint_room)}\e[0m"
        end
      end

      private def truncate(text : String, width : Int) : String
        return text if text.size <= width
        return text[0, width] if width < 4
        "#{text[0, width - 1]}…"
      end

      private def cleanup
        @tty.print("\e[#{@rows + 1}A\r\e[J")
        @tty.flush
      end

      # ---------- Input ----------

      # Reads a single keystroke, decoding escape sequences (arrow keys,
      # PageUp/Down). Returns one of:
      #   :up :down :page_up :page_down :enter :cancel :backspace
      #   Char  (printable filter input)
      #   nil   (unknown sequence, ignore)
      private def read_action
        c = blocking_read_char
        return :cancel if c.nil?
        case c
        when '\u0003', '\u0004' then :cancel # Ctrl-C / Ctrl-D
        when '\r', '\n'         then :enter
        when '\u007f', '\b'     then :backspace
        when '\e'               then read_escape_sequence
        else                         c
        end
      end

      private def read_escape_sequence
        # After ESC, peek with a short timeout. If nothing comes (bare
        # ESC), the user wants to cancel.
        with_brief_timeout do
          n = @tty.read_char
          return :cancel if n.nil?
          if n == '['
            arrow = @tty.read_char
            return if arrow.nil?
            case arrow
            when 'A' then :up
            when 'B' then :down
            when '5'
              @tty.read_char # consume trailing '~'
              :page_up
            when '6'
              @tty.read_char
              :page_down
            end
          end
        end
      end

      # ---------- Cursor / scrolling ----------

      private def move(delta : Int32)
        filtered = Picker.filter(@items, @query)
        return if filtered.empty?
        @cursor = (@cursor + delta).clamp(0, filtered.size - 1)
      end

      # ---------- Termios ----------

      private def blocking_read_char : Char?
        @tty.read_char
      end

      private def with_raw_mode(&)
        original = uninitialized LibC::Termios
        if LibC.tcgetattr(@tty.fd, pointerof(original)) != 0
          # Couldn't read terminal state — bail without modifying it.
          yield
          return
        end

        raw = original
        raw.c_lflag &= ~(LibC::ICANON | LibC::ECHO | LibC::ISIG)
        raw.c_cc[VMIN] = 1
        raw.c_cc[VTIME] = 0
        LibC.tcsetattr(@tty.fd, LibC::TCSANOW, pointerof(raw))
        @tty.print("\e[?25l") # hide cursor
        @tty.flush

        begin
          yield
        ensure
          @tty.print("\e[?25h") # restore cursor
          @tty.flush
          LibC.tcsetattr(@tty.fd, LibC::TCSANOW, pointerof(original))
        end
      end

      # Switch to a 100ms read timeout, run the block, then switch back.
      # Used for the bare-ESC vs escape-sequence disambiguation.
      private def with_brief_timeout(&)
        attrs = uninitialized LibC::Termios
        return yield if LibC.tcgetattr(@tty.fd, pointerof(attrs)) != 0

        prev_min = attrs.c_cc[VMIN]
        prev_time = attrs.c_cc[VTIME]
        attrs.c_cc[VMIN] = 0
        attrs.c_cc[VTIME] = 1
        LibC.tcsetattr(@tty.fd, LibC::TCSANOW, pointerof(attrs))

        begin
          yield
        ensure
          attrs.c_cc[VMIN] = prev_min
          attrs.c_cc[VTIME] = prev_time
          LibC.tcsetattr(@tty.fd, LibC::TCSANOW, pointerof(attrs))
        end
      end

      private def printable?(c : Char) : Bool
        # Treat any non-control byte as filter input. Crystal's `Char`
        # has `#printable?` for ASCII; we extend tolerance to multibyte
        # codepoints (Korean, etc.) by accepting anything > 0x1f and
        # not == 0x7f.
        ord = c.ord
        ord >= 0x20 && ord != 0x7f
      end
    end
  end
end
