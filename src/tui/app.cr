require "base64"
require "termisu"
require "../db/database"
require "../models/entry"
require "../utils/validator"
require "../services/picker"
require "./query"

module Doma
  module TUI
    # The interactive fuzzy finder. Owns the `Termisu` instance and the whole
    # render + event loop; this is the *only* file coupled to termisu, so an
    # upstream API change touches one place (the pure `Query`/`Fuzzy` core
    # stays insulated).
    #
    # termisu draws exclusively on /dev/tty, so the TUI never touches STDOUT —
    # the caller (`TuiCommand`) prints the chosen path to STDOUT *after* the
    # screen is torn down, preserving the `cd "$(doma)"` contract used by the
    # shell wrapper (identical to `list --pick`).
    #
    # Layout: the result list fills the top, with the search box pinned to the
    # bottom row and a dim status/keyhint line just above it.
    class App
      record Result, path : String?, cancelled : Bool do
        def self.cancelled : Result
          new(nil, true)
        end

        def self.selected(path : String) : Result
          new(path, false)
        end

        def selected? : Bool
          !cancelled && !path.nil?
        end
      end

      enum Mode
        Browsing
        AddPath
        AddTags
      end

      # Constructs the TUI and enters raw mode + the alternate screen. Raises
      # `IO::Error` when there's no controlling terminal — the caller turns
      # that into a clean user-facing error.
      def initialize(@db : Doma::Database, @entries : Array(Doma::Entry), query : String = "")
        @termisu = Termisu.new
        @query = query
        @cursor = 0
        @offset = 0
        @width = 0
        @height = 0
        @list_height = 1
        @mode = Mode::Browsing
        @buffer = ""
        @pending_path = ""
        @status = ""
        @status_error = false
        @show_help = false
        # Whether a shell wrapper will `cd` into the selection. The wrapper
        # (`doma setup init`) hands us a DOMA_CD_FILE to write the chosen path
        # to; without it, Enter only *prints* the path — so the footer must
        # not promise `cd`.
        @shell_integration = !ENV["DOMA_CD_FILE"]?.presence.nil?
        @scored = Query.filter(@entries, Query.parse(@query))
      end

      # Runs the event loop until the user selects (Enter) or cancels
      # (Esc/Ctrl-C). Always restores the terminal, even on a mid-session TTY
      # hangup (treated as a cancel, mirroring `Picker`'s hardening).
      def run : Result
        loop do
          render
          event = @termisu.poll_event
          case event
          when Termisu::Event::Key
            result = @mode.browsing? ? handle_browse_key(event) : handle_prompt_key(event)
            return result if result
          when Termisu::Event::Resize
            @termisu.sync
          end
        end
      rescue IO::Error
        Result.cancelled
      ensure
        close
      end

      private def close
        @termisu.show_cursor
        @termisu.close
      rescue IO::Error
        # Terminal already gone (hangup); nothing left to restore.
      end

      # ---------------- Event handling ----------------

      private def handle_browse_key(event : Termisu::Event::Key) : Result?
        return Result.cancelled if event.ctrl_c?

        if @show_help
          @show_help = false
          return
        end

        @status = ""
        return Result.cancelled if event.key.escape?

        if event.ctrl?
          case
          when event.key.a? then begin_add
          when event.key.y? then copy_current
          when event.key.p? then move(-1)
          when event.key.n? then move(+1)
          end
          return
        end

        case
        when event.key.enter?
          return select_current
        when event.key.up?        then move(-1)
        when event.key.down?      then move(+1)
        when event.key.page_up?   then move(-@list_height)
        when event.key.page_down? then move(+@list_height)
        when event.key.f1?        then @show_help = true
        when event.key.backspace?
          unless @query.empty?
            @query = @query[0...-1]
            refilter
          end
        when event.key.question? && @query.empty?
          @show_help = true
        else
          append_query(event)
        end
        nil
      end

      private def handle_prompt_key(event : Termisu::Event::Key) : Result?
        return Result.cancelled if event.ctrl_c?

        case
        when event.key.escape?
          @mode = Mode::Browsing
          @buffer = ""
        when event.key.enter?
          submit_prompt
        when event.key.backspace?
          @buffer = @buffer[0...-1] unless @buffer.empty?
        else
          if (c = event.char) && printable?(c) && !event.ctrl? && !event.alt?
            @buffer += c
          end
        end
        nil
      end

      private def append_query(event : Termisu::Event::Key)
        return if event.ctrl? || event.alt?
        c = event.char
        return unless c && printable?(c)
        @query += c
        refilter
      end

      private def select_current : Result?
        sc = @scored[@cursor]?
        sc ? Result.selected(sc.entry.path) : nil
      end

      private def move(delta : Int32)
        return if @scored.empty?
        @cursor = (@cursor + delta).clamp(0, @scored.size - 1)
        adjust_offset
      end

      private def adjust_offset
        return if @list_height < 1
        if @cursor < @offset
          @offset = @cursor
        elsif @cursor >= @offset + @list_height
          @offset = @cursor - @list_height + 1
        end
      end

      private def refilter
        @scored = Query.filter(@entries, Query.parse(@query))
        @cursor = 0
        @offset = 0
      end

      private def reload
        @entries = @db.directories(sort: Doma::Database::SortBy::Recent)
        refilter
      end

      # ---------------- In-app actions ----------------

      private def begin_add
        @mode = Mode::AddPath
        @buffer = current_dir
      end

      # Dir.current raises if the cwd was deleted out from under us; fall back
      # to an empty prompt (perform_add then defaults to the cwd again, under
      # its own rescue) rather than crashing the session.
      private def current_dir : String
        Dir.current
      rescue
        ""
      end

      private def submit_prompt
        case @mode
        when .add_path?
          @pending_path = @buffer.strip
          @buffer = ""
          @mode = Mode::AddTags
        when .add_tags?
          perform_add(@pending_path, @buffer.strip)
          @buffer = ""
          @mode = Mode::Browsing
        end
      end

      private def perform_add(path : String, tags_raw : String)
        raw = path.empty? ? current_dir : path
        abs = Doma::Validator.path!(raw)
        names = tags_raw.split.reject(&.empty?)
        tags = names.empty? ? [] of String : Doma::Validator.tags!(names)
        # Path already validated above; skip db.add's redundant re-validation
        # (matches AddCommand).
        @db.add(abs, tags, validate_path: false)
        reload
        set_status("added #{abs}", error: false)
      rescue ex : Doma::Error
        set_status(ex.message || "add failed", error: true)
      rescue ex
        # An interactive add must never tear down the session — surface any
        # other failure (DB hiccup, missing cwd) as a status message.
        set_status("add failed: #{ex.message}", error: true)
      end

      # OSC-52 clipboard write straight to /dev/tty — no subprocess. Silently
      # best-effort: terminals that don't support it just ignore the sequence.
      private def copy_current
        sc = @scored[@cursor]?
        return unless sc
        seq = "\e]52;c;#{Base64.strict_encode(sc.entry.path)}\a"
        File.open("/dev/tty", "w") do |tty|
          tty.print(seq)
          tty.flush
        end
        set_status("copied path", error: false)
      rescue
        set_status("copy not supported by this terminal", error: true)
      end

      private def set_status(message : String, *, error : Bool)
        @status = message
        @status_error = error
      end

      # ---------------- Rendering ----------------

      private def render
        @width, @height = @termisu.size
        @termisu.clear

        if @height < 3 || @width < 12
          draw_text(0, 0, "window too small", fg: Termisu::Color.bright_black)
          @termisu.render
          return
        end

        @list_height = @height - 2
        if @show_help
          render_help
        else
          render_list
        end
        render_status(@height - 2)
        render_input(@height - 1)
        @termisu.render
      end

      private def render_list
        if @scored.empty?
          message = @entries.empty? ? "no directories registered" : "no matches"
          draw_text(2, 0, message, fg: Termisu::Color.bright_black)
          return
        end

        adjust_offset
        last = Math.min(@offset + @list_height, @scored.size)
        row = 0
        (@offset...last).each do |i|
          draw_row(row, @scored[i], i == @cursor)
          row += 1
        end
      end

      private def draw_row(y : Int32, scored : Query::Scored, selected : Bool)
        base = selected ? Termisu::Attribute::Reverse : Termisu::Attribute::None
        marker = selected ? '▌' : ' '
        @termisu.set_cell(0, y, marker, fg: Termisu::Color.cyan, attr: base)

        hint = scored.entry.tags.empty? ? "" : Picker.sanitize(scored.entry.tags.map { |t| "##{t}" }.join(" "))
        hint_room = hint.empty? ? 0 : Math.min(text_width(hint), (@width // 3).clamp(8, 60))
        label_limit = @width - (hint.empty? ? 1 : hint_room + 3)

        draw_path(2, y, scored, base, selected, label_limit)

        unless hint.empty?
          draw_text(@width - hint_room, y, hint, fg: Termisu::Color.bright_black, attr: base, max_x: @width)
        end
      end

      private def draw_path(x : Int32, y : Int32, scored : Query::Scored, base : Termisu::Attribute, selected : Bool, limit : Int32)
        path = Picker.sanitize(scored.entry.path)
        positions = scored.positions
        col = x
        index = 0
        path.each_char do |ch|
          w = char_width(ch)
          if col + w > limit
            @termisu.set_cell(col, y, '…', fg: Termisu::Color.bright_black, attr: base) if col < limit
            break
          end
          matched = positions.includes?(index)
          if matched
            fg = selected ? Termisu::Color.white : Termisu::Color.bright_yellow
            attr = base | Termisu::Attribute::Bold
          else
            fg = selected ? Termisu::Color.white : Termisu::Color.default
            attr = base
          end
          @termisu.set_cell(col, y, ch, fg: fg, attr: attr)
          col += w
          index += 1
        end
      end

      private def render_status(y : Int32)
        if !@status.empty?
          color = @status_error ? Termisu::Color.red : Termisu::Color.green
          draw_text(2, y, Picker.sanitize(@status), fg: color, max_x: @width)
          return
        end

        count = "#{@scored.size}/#{@entries.size}"
        enter = @shell_integration ? "enter cd" : "enter print"
        keys = "↑↓ move · #{enter} · ^a add · ^y copy · ? help · esc quit"
        line = "#{count}   #{keys}"
        draw_text(2, y, line, fg: Termisu::Color.bright_black, max_x: @width)
      end

      private def render_input(y : Int32)
        prompt, text =
          case @mode
          when .add_path? then {"add path › ", @buffer}
          when .add_tags? then {"tags (space-separated) › ", @buffer}
          else                 {"› ", @query}
          end

        start = draw_text(0, y, prompt, fg: Termisu::Color.cyan, attr: Termisu::Attribute::Bold, max_x: @width)
        cursor_col = draw_text(start, y, Picker.sanitize(text), fg: Termisu::Color.default, max_x: @width)
        @termisu.set_cursor(Math.min(cursor_col, @width - 1), y, true)
      end

      private def render_help
        enter_desc = @shell_integration ? "cd to entry" : "print path to stdout"
        lines = [
          {"doma tui — fuzzy finder", Termisu::Color.cyan, Termisu::Attribute::Bold},
          {"", Termisu::Color.default, Termisu::Attribute::None},
          {"Query operators:", Termisu::Color.bright_white, Termisu::Attribute::Bold},
          {"  tag:NAME    only entries with a matching tag (glob: tag:web/*)", Termisu::Color.default, Termisu::Attribute::None},
          {"  -tag:NAME   exclude a tag (also !tag:NAME)", Termisu::Color.default, Termisu::Attribute::None},
          {"  id:PREFIX   match a short-id prefix", Termisu::Color.default, Termisu::Attribute::None},
          {"  path:TERM   fuzzy-match the whole path (no basename bias)", Termisu::Color.default, Termisu::Attribute::None},
          {"", Termisu::Color.default, Termisu::Attribute::None},
          {"Keys:", Termisu::Color.bright_white, Termisu::Attribute::Bold},
          {"  ↑/↓  ^p/^n   move          enter    #{enter_desc}", Termisu::Color.default, Termisu::Attribute::None},
          {"  pgup/pgdn    page          ^a       add a directory", Termisu::Color.default, Termisu::Attribute::None},
          {"  ^y           copy path     esc/^c   quit", Termisu::Color.default, Termisu::Attribute::None},
          {"  f1 / ?       toggle help", Termisu::Color.default, Termisu::Attribute::None},
        ]
        # When no shell wrapper is capturing stdout, Enter can't change the
        # parent shell's cwd — point the user at the one-time setup that lets
        # it, instead of silently under-delivering on the "cd" hint.
        unless @shell_integration
          lines << {"", Termisu::Color.default, Termisu::Attribute::None}
          lines << {"Enter prints the path; run `doma setup install` to cd on Enter.", Termisu::Color.yellow, Termisu::Attribute::None}
        end
        lines << {"", Termisu::Color.default, Termisu::Attribute::None}
        lines << {"press any key to close", Termisu::Color.bright_black, Termisu::Attribute::Italic}
        lines.each_with_index do |line, i|
          break if i >= @list_height
          text, fg, attr = line
          draw_text(2, i, text, fg: fg, attr: attr, max_x: @width)
        end
      end

      # ---------------- Drawing primitives ----------------

      # Draws `text` starting at (x, y), advancing by each character's display
      # width so CJK/Hangul lay out correctly. Returns the column just past the
      # last drawn cell. Stops at `max_x` (defaults to the screen width).
      private def draw_text(x : Int32, y : Int32, text : String, *, fg : Termisu::Color = Termisu::Color.default, attr : Termisu::Attribute = Termisu::Attribute::None, max_x : Int32? = nil) : Int32
        limit = max_x || @width
        col = x
        text.each_char do |ch|
          w = char_width(ch)
          break if col + w > limit
          @termisu.set_cell(col, y, ch, fg: fg, attr: attr)
          col += w
        end
        col
      end

      private def text_width(text : String) : Int32
        text.each_char.sum { |ch| char_width(ch) }
      end

      private def char_width(ch : Char) : Int32
        Termisu::UnicodeWidth.codepoint_width(ch.ord).to_i
      end

      private def printable?(c : Char) : Bool
        ord = c.ord
        ord >= 0x20 && ord != 0x7f
      end
    end
  end
end
