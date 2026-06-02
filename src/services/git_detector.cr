require "../utils/validator"

module Doma
  # Pulls metadata from a `.git/config` file without spawning git itself.
  # Returns an empty result when the path isn't a git working tree, when the
  # config can't be read, or when the remote URL is shaped in a way we can't
  # confidently parse — never raises, since auto-tagging is best-effort.
  module GitDetector
    extend self

    record Info,
      git : Bool,
      host : String?,
      owner : String?,
      repo : String? do
      # Tags worth attaching when --git-tag is on. Host + repo: enough
      # selectivity to be useful as a filter. Owner is intentionally
      # excluded because in practice it tends to be either the user
      # themselves (noisy) or one of several orgs (causing tag explosion).
      # A bare `git` tag would land on every git repo and add zero
      # filtering signal — `auto_tag.git=true` users would just see
      # `#git` everywhere — so it's left off.
      def to_tags : Array(String)
        out = [] of String
        if host = self.host
          out << host
        end
        if repo = self.repo
          out << repo
        end
        out.uniq!
      end
    end

    EMPTY = Info.new(false, nil, nil, nil)

    def detect(path : String) : Info
      git_dir = locate_git_dir(Doma::Validator.expand_home(path))
      return EMPTY unless git_dir
      url = read_origin_url(git_dir)
      return Info.new(true, nil, nil, nil) unless url
      parsed = parse_remote(url)
      Info.new(true, parsed[:host], parsed[:owner], parsed[:repo])
    end

    # Walks up from `start` looking for a directory containing a `.git` entry
    # (either a directory or a worktree gitdir file). Stops at the filesystem
    # root.
    private def locate_git_dir(start : String) : String?
      current = start
      loop do
        candidate = File.join(current, ".git")
        if Dir.exists?(candidate)
          return candidate
        elsif File.file?(candidate)
          # `.git` file points at a real gitdir (worktrees, submodules).
          if line = File.read_lines(candidate).find(&.starts_with?("gitdir:"))
            ref = line.sub("gitdir:", "").strip
            ref = File.expand_path(ref, current) unless ref.starts_with?('/')
            return ref if Dir.exists?(ref)
          end
        end
        parent = File.dirname(current)
        return if parent == current
        current = parent
      end
    end

    # Resolve the `config` file that holds the remote URL. A primary
    # checkout keeps it right inside `.git/`, but a linked worktree's
    # gitdir (`.git/worktrees/<name>`) and a submodule's gitdir hold no
    # `config` of their own — the shared one lives in the common dir,
    # pointed at by a `commondir` file (typically `../..`). Without
    # following it, `--git-tag` silently produced no host/repo tags for
    # every worktree and submodule. Returns nil when no readable config
    # is found on either path.
    private def config_path_for(git_dir : String) : String?
      direct = File.join(git_dir, "config")
      return direct if File.file?(direct)

      commondir_file = File.join(git_dir, "commondir")
      if File.file?(commondir_file)
        ref = File.read(commondir_file).strip
        unless ref.empty?
          common = ref.starts_with?('/') ? ref : File.expand_path(ref, git_dir)
          shared = File.join(common, "config")
          return shared if File.file?(shared)
        end
      end

      nil
    end

    private def read_origin_url(git_dir : String) : String?
      cfg = config_path_for(git_dir)
      return unless cfg
      in_origin = false
      File.each_line(cfg) do |line|
        stripped = line.strip
        if stripped.starts_with?('[')
          in_origin = stripped == "[remote \"origin\"]"
          next
        end
        next unless in_origin
        if stripped.starts_with?("url")
          parts = stripped.split('=', 2)
          return parts[1].strip if parts.size == 2
        end
      end
      nil
    end

    # Handles the three forms commonly seen in `.git/config`:
    #   https://github.com/owner/repo.git
    #   git@github.com:owner/repo.git
    #   ssh://git@github.com/owner/repo
    private def parse_remote(url : String) : NamedTuple(host: String?, owner: String?, repo: String?)
      stripped = url.strip
      stripped = stripped.rchop(".git") if stripped.ends_with?(".git")

      if m = stripped.match(/\A[a-z]+:\/\/(?:[^@\/]+@)?([^\/]+)\/(.+?)\/([^\/]+)\z/i)
        return {host: host_label(m[1]), owner: m[2], repo: m[3]}
      end
      if m = stripped.match(/\A(?:[^@]+)@([^:]+):(.+?)\/([^\/]+)\z/)
        return {host: host_label(m[1]), owner: m[2], repo: m[3]}
      end
      {host: nil, owner: nil, repo: nil}
    end

    # Map raw hostnames to short, friendly labels. Unknown hosts pass through
    # unchanged so users on self-hosted Forgejo/Gitea/etc still get a tag.
    private def host_label(host : String) : String
      h = host.downcase
      case
      when h.includes?("github.com")    then "github"
      when h.includes?("gitlab.com")    then "gitlab"
      when h.includes?("bitbucket.org") then "bitbucket"
      when h.includes?("codeberg.org")  then "codeberg"
      else                                   h
      end
    end
  end
end
