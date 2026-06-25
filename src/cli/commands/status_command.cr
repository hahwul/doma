require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../services/git_status"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/parallel"
require "../../utils/suggester"
require "../../utils/tag_glob"

module Doma::CLI
  # Git status across a set of tagged directories — the read-only twin of
  # `run`. Where `run` executes a command in every tagged repo, `status`
  # reports each repo's working-tree state (branch, ahead/behind, dirty
  # count) in one glance.
  #
  #   doma status                 → every tracked directory
  #   doma status work            → directories tagged `work`
  #   doma status 'work/*'        → glob over tags (shell semantics)
  #   doma status -t work --dirty → only repos with uncommitted changes
  class StatusCommand
    # IO-bound (each probe forks git), so parallel-by-default with a
    # CPU-count cap is the right shape; `--jobs` tunes it for slow disks
    # or huge sets. Floor at 1 so a 0-core helper return never stalls.
    private DEFAULT_JOBS = {System.cpu_count.to_i, 1}.max

    # One directory's resolved state. `exists` is tracked separately from
    # the git Status so a gone path (✗ gone) reads differently from a
    # live non-repo directory (✗ not a git repo).
    private record RepoState,
      entry : Doma::Entry,
      exists : Bool,
      status : Doma::GitStatus::Status

    def run(args : Array(String))
      json_mode = false
      dirty_only = false
      jobs : Int32? = nil
      flag_tags = [] of String
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma status [<tag> | -t TAG] [--dirty] [--jobs N] [--json]"
        p.on("-t TAG", "--tag=TAG", "Tag selector (single tag; alias for positional)") do |t|
          raise Doma::ValidationError.new("tag is empty (-t got an empty value)") if t.strip.empty?
          flag_tags << t
        end
        p.on("--dirty", "Only show repos with uncommitted changes") { dirty_only = true }
        p.on("--jobs N", "Max concurrent git probes (default: CPU count)") do |n|
          parsed = n.to_i?
          raise Doma::ValidationError.new("--jobs must be a positive integer, got '#{n}'") if parsed.nil? || parsed < 1
          jobs = parsed
        end
        p.on("--json", "Output as JSON") { json_mode = true }
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Probes each directory with `git status` and reports branch,"
          STDOUT.puts "ahead/behind vs upstream, and a dirty-file count. With no tag,"
          STDOUT.puts "every tracked directory is scanned. Non-git and missing paths"
          STDOUT.puts "are shown too (use --dirty to hide everything that's clean)."
          exit 0
        end
        p.unknown_args do |before, after|
          positional.concat(before)
          positional.concat(after)
        end
      end
      parser.parse(args)

      if !flag_tags.empty? && !positional.empty?
        raise Doma::ValidationError.new("tag specified both positionally and via -t; pick one")
      end
      if flag_tags.size > 1
        raise Doma::ValidationError.new("status accepts a single tag; got #{flag_tags.size} via -t")
      end
      if positional.size > 1
        raise Doma::ValidationError.new("status accepts a single tag; got #{positional.size} positional args")
      end
      tag = flag_tags.first? || positional.first?

      # Fail fast and clearly if git isn't installed — otherwise every
      # directory would probe to "not a git repo" and the user would
      # chase a phantom problem.
      unless Doma::GitStatus.available?
        raise Doma::Error.new(
          "git executable not found on PATH",
          hint: "`doma status` shells out to git; install it or put it on your PATH"
        )
      end

      db = Doma::Database.open
      entries, all_tags = begin
        {resolve_entries(db, tag), db.tag_names}
      ensure
        db.close
      end

      if entries.empty?
        if tag
          raise Doma::NotFoundError.new(
            "no directories tagged '#{tag}'",
            hint: Doma::Suggester.tag_hint_for(tag, all_tags)
          )
        else
          Doma::Logger.info "nothing tracked yet — `doma add <path> -t <tag>` to start"
          return
        end
      end

      states = probe_all(entries, jobs)
      states = states.select { |s| s.exists && s.status.clean? == false && s.status.git } if dirty_only

      if json_mode
        emit_json(states)
        return
      end

      if states.empty?
        # Only reachable under --dirty: everything matched was clean.
        Doma::Logger.info tag ? "all '#{tag}' repos are clean" : "all repos are clean"
        return
      end

      render_text(states)
    end

    # Mirrors `run`/`list`: a tag containing glob metacharacters is
    # post-filtered with shell-glob semantics (SQLite GLOB lets `*`
    # cross `/`; TagGlob doesn't), and no tag means the whole board.
    private def resolve_entries(db : Doma::Database, tag : String?) : Array(Doma::Entry)
      return db.directories(nil, sort: Doma::Database::SortBy::Path) unless tag

      entries = db.directories(tag, sort: Doma::Database::SortBy::Path)
      if tag.includes?('*') || tag.includes?('?')
        entries = entries.select do |e|
          e.tags.any? { |t| Doma::TagGlob.match?(tag, t) }
        end
      end
      entries
    end

    # Bounded fan-out over the directory set (see Doma::Parallel). Each
    # probe forks git, and Process.run yields the fiber while the child
    # runs, so the sweep overlaps real subprocess time even on doma's
    # single-threaded runtime — the same reason `run --parallel` is a win.
    # Results come back in input order, so the rendered table stays
    # path-sorted regardless of which probe finishes first.
    private def probe_all(entries : Array(Doma::Entry), jobs : Int32?) : Array(RepoState)
      Doma::Parallel.map(entries, jobs || DEFAULT_JOBS) do |entry|
        inspect_one(entry)
      rescue
        # Degrade cleanly: one probe blowing up must never abort the sweep.
        RepoState.new(entry, Dir.exists?(entry.path), Doma::GitStatus::NON_GIT)
      end
    end

    private def inspect_one(entry : Doma::Entry) : RepoState
      return RepoState.new(entry, false, Doma::GitStatus::NON_GIT) unless Dir.exists?(entry.path)
      RepoState.new(entry, true, Doma::GitStatus.probe(entry.path))
    end

    # ---------- rendering ----------

    private def render_text(states : Array(RepoState))
      color = Doma::Logger.color_enabled?
      width = states.max_of(&.entry.path.size)

      states.each do |s|
        path = color ? s.entry.path.colorize(:cyan).to_s : s.entry.path
        # ljust on the *raw* path; colorized strings carry invisible ANSI
        # bytes that would throw the column math off.
        pad = " " * (width - s.entry.path.size)
        cells = [status_cell(s, color), branch_cell(s, color), ab_cell(s, color)]
          .reject(&.empty?).join("  ")
        puts "#{path}#{pad}  #{cells}".rstrip
      end

      puts ""
      puts summary_line(states, color)
    end

    private def status_cell(s : RepoState, color : Bool) : String
      unless s.exists
        return color ? "✗ gone".colorize(:red).to_s : "✗ gone"
      end
      unless s.status.git
        return color ? "✗ not a git repo".colorize(:dark_gray).to_s : "✗ not a git repo"
      end
      if s.status.clean?
        return color ? "✔ clean".colorize(:green).to_s : "✔ clean"
      end
      label = "● #{s.status.dirty} dirty"
      color ? label.colorize(:yellow).to_s : label
    end

    private def branch_cell(s : RepoState, color : Bool) : String
      return "" unless s.exists && s.status.git
      name = s.status.detached ? "(detached)" : s.status.branch
      return "" unless name
      color ? name.colorize(:magenta).to_s : name
    end

    private def ab_cell(s : RepoState, color : Bool) : String
      return "" unless s.exists && s.status.git
      st = s.status
      parts = [] of String
      parts << "↓#{st.behind}" if st.behind > 0
      parts << "↑#{st.ahead}" if st.ahead > 0
      return "" if parts.empty?
      out = parts.join(' ')
      color ? out.colorize(:yellow).to_s : out
    end

    private def summary_line(states : Array(RepoState), color : Bool) : String
      dirty = states.count { |s| s.exists && s.status.git && !s.status.clean? }
      ahead = states.count { |s| s.exists && s.status.git && s.status.ahead > 0 }
      behind = states.count { |s| s.exists && s.status.git && s.status.behind > 0 }
      gone = states.count { |s| !s.exists }

      bits = ["#{states.size} repo#{states.size == 1 ? "" : "s"}"]
      bits << "#{dirty} dirty" if dirty > 0
      bits << "#{ahead} ahead" if ahead > 0
      bits << "#{behind} behind" if behind > 0
      bits << "#{gone} gone" if gone > 0
      line = bits.join(" · ")
      color ? line.colorize(:dark_gray).to_s : line
    end

    private def emit_json(states : Array(RepoState))
      str = JSON.build do |json|
        json.array do
          states.each do |s|
            json.object do
              json.field "path", s.entry.path
              json.field "short_id", s.entry.short_id
              json.field "tags" do
                json.array { s.entry.tags.each { |t| json.string t } }
              end
              json.field "exists", s.exists
              json.field "git", s.status.git
              if s.exists && s.status.git
                st = s.status
                json.field "branch", st.branch
                json.field "upstream", st.upstream
                json.field "detached", st.detached
                json.field "ahead", st.ahead
                json.field "behind", st.behind
                json.field "modified", st.modified
                json.field "staged", st.staged
                json.field "unstaged", st.unstaged
                json.field "untracked", st.untracked
                json.field "conflicts", st.conflicts
                json.field "dirty", st.dirty
                json.field "clean", st.clean?
              end
            end
          end
        end
      end
      puts str
    end
  end
end
