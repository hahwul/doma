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
    # and nested checkouts inside it aren't listed. Hidden directories,
    # SKIP names, and symlinks (loops, duplicates) aren't descended.
    def repos(root : String) : Array(String)
      found = [] of String
      walk(root, 0, found)
      found.sort!
    end

    private def walk(dir : String, depth : Int32, found : Array(String)) : Nil
      if File.exists?(File.join(dir, ".git"))
        found << dir
        return
      end
      return if depth >= MAX_DEPTH
      Dir.each_child(dir) do |name|
        next if name.starts_with?('.') || SKIP.includes?(name)
        child = File.join(dir, name)
        next if File.symlink?(child) || !Dir.exists?(child)
        walk(child, depth + 1, found)
      end
    rescue File::Error
      # Unreadable directory: skip it, keep scanning its siblings.
    end
  end
end
