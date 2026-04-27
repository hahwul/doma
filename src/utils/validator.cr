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
      return if cleaned.empty?
      cleaned = cleaned[0, MAX_TAG_LEN]
      cleaned.matches?(TAG_PATTERN) ? cleaned : nil
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
      expanded = File.expand_path(raw, home: true)
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
