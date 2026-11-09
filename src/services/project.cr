module Doma
  # What kind of project a directory is (from marker files) and where the
  # git repos under a tree are — feeds `add --project-tag` and `add -r`.
  # Plain file checks only: no parsing, no git subprocess.
  module Project
    extend self

    # Marker file → tag. A directory can carry several (a Crystal CLI with
    # a package.json for its docs site is both `crystal` and `node`).
    MARKERS = {
      "shard.yml"        => "crystal",
      "Cargo.toml"       => "rust",
      "go.mod"           => "go",
      "package.json"     => "node",
      "pyproject.toml"   => "python",
      "setup.py"         => "python",
      "requirements.txt" => "python",
      "Gemfile"          => "ruby",
      "mix.exs"          => "elixir",
      "pom.xml"          => "java",
      "build.gradle"     => "java",
      "build.gradle.kts" => "kotlin",
      "Package.swift"    => "swift",
      "composer.json"    => "php",
      "CMakeLists.txt"   => "cpp",
    }

    def types(dir : String) : Array(String)
      MARKERS.compact_map { |file, tag| tag if File.file?(File.join(dir, file)) }.uniq!
    end

    # ponytail: fixed depth, enough for ~/src/host/owner/repo; add a
    # --depth flag if someone keeps repos deeper.
    MAX_DEPTH = 4
    # Dependency/build output outside any repo (the walk never enters a
    # repo): can be huge and may hold vendored checkouts nobody tags.
    SKIP = %w[node_modules vendor target dist build]

    # Git repos at or under `root`, sorted. A repo is a leaf — submodules
    # and nested checkouts inside it aren't listed. Any child that is a
    # repo counts (hidden or not); only non-repo hidden dirs, SKIP names,
    # and symlinks (loops, duplicates) aren't descended. An unreadable
    # `root` raises; an unreadable directory below it is skipped.
    def repos(root : String) : Array(String)
      return [root] if repo?(root)
      found = [] of String
      walk(root, 1, found)
      found.sort!
    end

    private def repo?(dir : String) : Bool
      File.exists?(File.join(dir, ".git"))
    end

    private def walk(dir : String, depth : Int32, found : Array(String)) : Nil
      Dir.each_child(dir) do |name|
        child = File.join(dir, name)
        # lstat: a symlink reports as a symlink, not as its target.
        next unless File.info?(child, follow_symlinks: false).try(&.directory?)
        if repo?(child)
          found << child
        elsif depth < MAX_DEPTH && !name.starts_with?('.') && !SKIP.includes?(name)
          walk(child, depth + 1, found)
        end
      end
    rescue ex : File::Error
      raise ex if depth == 1
    end
  end
end
