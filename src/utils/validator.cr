require "./errors"

module Doma
  # Boundary validation for user input. Anything that ends up persisted in
  # the database flows through here so the storage layer never sees garbage.
  module Validator
    extend self

    TAG_PATTERN  = /\A[A-Za-z0-9][A-Za-z0-9_.\-+:\/]{0,63}\z/
    MAX_TAG_LEN  =   64
    MAX_PATH_LEN = 4096

    # Returns the canonicalized tag or raises ValidationError.
    def tag!(raw : String) : String
      cleaned = raw.strip
      raise ValidationError.new("tag is empty") if cleaned.empty?
      if cleaned.bytesize > MAX_TAG_LEN
        raise ValidationError.new("tag '#{cleaned}' exceeds #{MAX_TAG_LEN} bytes")
      end
      unless cleaned.matches?(TAG_PATTERN)
        raise ValidationError.new(
          "tag '#{cleaned}' is invalid (allowed: A-Z a-z 0-9 . _ - + : / starting alphanumeric)"
        )
      end
      # `/` is a hierarchy separator (see `tags --tree`), so an empty
      # segment is meaningless and renders as a blank/`/` node in the
      # tree. The pattern already blocks a leading slash (must start
      # alphanumeric); reject the trailing-`/` and doubled-`//` cases too
      # rather than persist a tag the tree view can't display sanely.
      if cleaned.ends_with?('/') || cleaned.includes?("//")
        raise ValidationError.new(
          "tag '#{cleaned}' has an empty path segment (no trailing or doubled '/')"
        )
      end
      cleaned
    end

    def tags!(raw : Enumerable(String)) : Array(String)
      raw.flat_map(&.split(','))
        .map(&.strip)
        .reject(&.empty?)
        .map { |t| tag!(t) }
        .uniq!
    end

    # Best-effort coercion of a string into a valid tag — used for *derived*
    # tags (basename, git repo name) where the user didn't choose the value
    # and we'd rather skip silently than break their `add` because their
    # repo happens to be named `.dotfiles`. Returns nil when no salvageable
    # tag can be produced.
    def sanitize_tag(raw : String) : String?
      return if raw.empty?
      cleaned = raw.gsub(/[^A-Za-z0-9_.\-+:\/]/, "")
      cleaned = cleaned.lstrip("._-+:/")
      # Collapse doubled slashes so a derived name never yields an empty
      # path segment — matching the rule `tag!` now enforces. Trailing
      # slashes are dropped both here and after the length trim, since the
      # cut can land on a `/` and re-expose one.
      cleaned = cleaned.gsub(%r{/{2,}}, "/").rstrip("/")
      return if cleaned.empty?
      cleaned = cleaned[0, MAX_TAG_LEN].rstrip("/")
      return if cleaned.empty?
      cleaned.matches?(TAG_PATTERN) ? cleaned : nil
    end

    # `~`/absolute-aware `File.expand_path` that survives a deleted cwd.
    #
    # `File.expand_path(path, home: true)` evaluates its `dir` default
    # (`Dir.current`) *eagerly*, so it raises "Error getting current
    # directory" even for absolute or `~`-rooted paths that never needed
    # the cwd. That turned a removed cwd into an "internal error:" on every
    # command that opens the DB (`list`, `tags`, `prune`, …) — including the
    # `prune --gone` you'd reach for precisely because a directory vanished.
    #
    # Supply the base explicitly and only touch the cwd when the path is
    # genuinely relative; absolute/`~` paths then resolve without it. When
    # the path *is* relative and the cwd is gone, recast the raw
    # "Error getting current directory" into a ValidationError so `add .`
    # from a deleted directory reads as an actionable message instead of
    # an "internal error:".
    def expand_home(raw : String) : String
      base = cwd_independent?(raw) ? "/" : current_dir_for(raw)
      File.expand_path(raw, base, home: true)
    end

    # True when the cwd plays no part in resolving `raw`: an absolute path,
    # or the only `~` form Crystal's `home: true` actually expands (`~` or
    # `~/…`). `~user` is deliberately excluded — Crystal does not do
    # per-user home lookup, so it stays a *relative* segment that must
    # resolve against the cwd, exactly as before this helper existed.
    private def cwd_independent?(raw : String) : Bool
      raw.starts_with?('/') || raw == "~" || raw.starts_with?("~/")
    end

    private def current_dir_for(raw : String) : String
      Dir.current
    rescue
      raise ValidationError.new(
        "cannot resolve relative path '#{raw}': the current directory is unavailable (was it deleted?)",
        hint: "cd into an existing directory, or pass an absolute path"
      )
    end

    # Canonicalize a user-supplied path. By default the path must exist; pass
    # `must_exist: false` for import flows that may reference paths from
    # other machines.
    def path!(raw : String, *, must_exist : Bool = true) : String
      cleaned = raw.strip
      raise ValidationError.new("path is empty") if cleaned.empty?
      abs = canonicalize(cleaned)
      if abs.bytesize > MAX_PATH_LEN
        raise ValidationError.new("path exceeds #{MAX_PATH_LEN} bytes")
      end
      if must_exist && !Dir.exists?(abs)
        raise ValidationError.new("not a directory: #{abs}")
      end
      abs
    end

    # Canonicalize a path. The single source of truth for path expansion
    # in this codebase — every call site previously used
    # `File.expand_path(path)` which silently leaves `~` literal, which
    # created the `<cwd>/~/...` bug we shipped earlier.
    #
    # When the path exists we resolve symlinks via `File.realpath` so
    # different aliases for the same directory normalize to a single row.
    # When it doesn't (import from another machine, or `move
    # --allow-missing` to a path not yet on disk), we walk up to the
    # closest existing ancestor, realpath that, and re-attach the
    # nonexistent trailing segments. Without that walk, `/tmp/foo`
    # would store as-is for an absent leaf and then collide with
    # `/private/tmp/foo` once the directory is created and re-added,
    # producing two rows for the same physical directory.
    #
    # Trailing slashes are stripped so `/tmp` and `/tmp/` are the same key.
    def canonicalize(raw : String) : String
      expanded = expand_home(raw)
      resolved = if File.exists?(expanded)
                   begin
                     File.realpath(expanded)
                   rescue
                     expanded
                   end
                 else
                   resolve_nonexistent(expanded)
                 end
      strip_trailing_slash(resolved)
    end

    private def resolve_nonexistent(path : String) : String
      trailing = [] of String
      current = path
      while !File.exists?(current)
        parent = File.dirname(current)
        break if parent == current # reached the root, give up
        trailing.unshift(File.basename(current))
        current = parent
      end
      return path unless File.exists?(current)

      real = begin
        File.realpath(current)
      rescue
        current
      end
      trailing.empty? ? real : File.join([real] + trailing)
    end

    private def strip_trailing_slash(path : String) : String
      return path if path == "/"
      path.ends_with?('/') ? path.rchop('/') : path
    end
  end
end
