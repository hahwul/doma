require "option_parser"
require "colorize"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/suggester"
require "../../utils/tag_glob"

module Doma::CLI
  # Runs a shell command in every directory matching the given tag.
  #
  #   doma run <tag> -- <cmd> [args...]
  class RunCommand
    # Default cap for `--parallel` when the user doesn't pass `--jobs`.
    # CPU count is the right shape for compute-bound sweeps (build,
    # test); for IO-bound sweeps (git fetch, npm install) the user
    # almost certainly wants a different number — that's what `--jobs`
    # is there to set. Falls back to 4 on platforms where the helper
    # returns 0 so we never spawn unbounded fibers by accident.
    private DEFAULT_JOBS = {System.cpu_count.to_i, 1}.max

    def run(args : Array(String))
      stop_on_fail = false
      parallel = false
      no_header = false
      jobs : Int32? = nil
      flag_tags = [] of String
      positional_tags = [] of String
      cmd_args = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma run (<tag> | -t TAG) [--fail-fast] [--parallel [--jobs N]] [--no-header] -- <cmd> [args...]"
        p.on("-t TAG", "--tag=TAG", "Tag selector — single tag, no comma split (alias for positional)") do |t|
          if t.strip.empty?
            raise Doma::ValidationError.new("tag is empty (-t got an empty value)")
          end
          flag_tags << t
        end
        p.on("--fail-fast", "Stop on first failure") { stop_on_fail = true }
        p.on("--parallel", "Run commands in parallel (best-effort, output interleaves)") { parallel = true }
        p.on("--jobs N", "Max concurrent invocations under --parallel (default: CPU count)") do |n|
          parsed = n.to_i?
          if parsed.nil? || parsed < 1
            raise Doma::ValidationError.new("--jobs must be a positive integer, got '#{n}'")
          end
          jobs = parsed
        end
        p.on("--no-header", "Suppress per-directory ▶/✓ markers (failures still surface as ✗)") { no_header = true }
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Runs <cmd> in every directory tagged with <tag>. The tag"
          STDOUT.puts "can be passed positionally (`run work -- cmd`) or via"
          STDOUT.puts "`-t TAG` (`run -t work -- cmd`), but not both. Only a"
          STDOUT.puts "single tag is accepted; glob patterns (`*`, `?`) still"
          STDOUT.puts "match across multiple tags."
          exit 0
        end
        p.unknown_args do |before, after|
          positional_tags.concat(before)
          cmd_args.concat(after)
        end
      end
      # Capture before parse: a bare `--` is consumed by the parser, so
      # we can't tell afterwards whether the user supplied a separator.
      had_separator = args.includes?("--")
      parser.parse(args)
      if jobs && !parallel
        raise Doma::ValidationError.new("--jobs requires --parallel")
      end
      # Global -q already implies --no-header — both want a quieter run.
      no_header ||= Doma::Logger.quiet?

      # Check the missing-command case first: if the user typed
      # `run -t shared echo hi` (no separator), `echo`/`hi` land in
      # positional_tags and would trip the "both forms" rule below
      # with a misleading message. Surfacing the real mistake (no `--`)
      # is what the user actually needs.
      if cmd_args.empty?
        # If they did write `--` but nothing followed, the original
        # message is exactly right. Otherwise they never used a separator
        # at all — don't tell them to look "after '--'" for one that isn't
        # there; teach the syntax and reconstruct their likely intent.
        raise Doma::ValidationError.new("command is required after '--'") if had_separator
        raise Doma::ValidationError.new(
          "no command to run — commands go after a '--' separator",
          hint: missing_separator_hint(flag_tags, positional_tags)
        )
      end

      if !flag_tags.empty? && !positional_tags.empty?
        raise Doma::ValidationError.new(
          "tag specified both positionally and via -t; pick one"
        )
      end
      if flag_tags.size > 1
        raise Doma::ValidationError.new(
          "run accepts a single tag; got #{flag_tags.size} via -t"
        )
      end
      tag_args = flag_tags.empty? ? positional_tags : flag_tags

      raise Doma::ValidationError.new("tag is required") if tag_args.empty?

      tag = tag_args.first
      db = Doma::Database.open
      paths, all_tags = begin
        # Use `directories(tag)` (returns Entry rows with their tag list)
        # rather than `paths_for_tag` so we can post-filter against the
        # strict glob rules. SQL GLOB treats `*` as crossing `/`; we
        # reimpose shell-glob semantics in Crystal so `run 'a/*' -- ...`
        # doesn't end up running in `a/b/c/d`.
        entries = db.directories(tag, sort: Doma::Database::SortBy::Recent)
        if tag.includes?('*') || tag.includes?('?')
          entries = entries.select do |e|
            e.tags.any? { |t| Doma::TagGlob.match?(tag, t) }
          end
        end
        {entries.map(&.path).uniq!, db.tag_names}
      ensure
        db.close
      end

      if paths.empty?
        raise Doma::NotFoundError.new(
          "no directories tagged '#{tag}'",
          hint: Doma::Suggester.tag_hint_for(tag, all_tags)
        )
      end

      cmd = cmd_args.first
      cmd_rest = cmd_args[1..]
      color = Doma::Logger.color_enabled?
      failures = 0

      if parallel
        Doma::Logger.warn "--fail-fast is ignored in --parallel mode" if stop_on_fail
        # Worker-pool over a bounded job channel. Without a cap, spawning
        # one fiber per directory was fine for a `pwd` sweep but a foot-
        # gun for `git fetch` / `npm install` style commands — 200
        # simultaneous network jobs would saturate the user's box.
        # Workers pull from `pending` until it's drained; results land
        # in `results` so the announcement loop can preserve a stable
        # consumer count regardless of how many workers we run.
        # Crystal narrows `jobs` (Int32?) only inside the closure; pull
        # it into a non-nil local before the clamp.
        j = jobs
        requested_jobs : Int32 = j.nil? ? DEFAULT_JOBS : j
        cap = requested_jobs.clamp(1, paths.size)
        pending = Channel(String).new(paths.size)
        results = Channel({String, Int32}).new(paths.size)

        paths.each { |path| pending.send(path) }
        pending.close

        cap.times do
          spawn do
            loop do
              path = pending.receive?
              break if path.nil?
              code = run_one(cmd, cmd_rest, path, attach_stdin: false)
              results.send({path, code})
            end
          end
        end

        paths.size.times do
          path, code = results.receive
          announce(path, code, color, no_header)
          failures += 1 unless code == 0
        end
      else
        paths.each do |path|
          unless no_header
            header = "▶ #{path}"
            STDERR.puts(color ? header.colorize(:cyan).bold.to_s : header)
          end
          code = run_one(cmd, cmd_rest, path, attach_stdin: true)
          announce(path, code, color, no_header)
          unless code == 0
            failures += 1
            break if stop_on_fail
          end
        end
      end

      exit(failures == 0 ? 0 : 1)
    end

    # Builds a "did you mean" line for the no-`--` mistake by
    # reconstructing the user's likely intent. With `-t TAG` every
    # positional is the command; otherwise the first positional is the
    # tag and the rest is the command. Falls back to the generic form
    # when there isn't enough to reconstruct.
    private def missing_separator_hint(flag_tags : Array(String), positional_tags : Array(String)) : String
      if !flag_tags.empty?
        cmd = positional_tags.join(" ")
        return "did you mean: doma run -t #{flag_tags.first} -- #{cmd}".rstrip if !cmd.empty?
      elsif positional_tags.size >= 2
        return "did you mean: doma run #{positional_tags.first} -- #{positional_tags[1..].join(" ")}"
      end
      "usage: doma run <tag> -- <cmd>"
    end

    # Runs a single instance, translating spawn/exec failures (missing
    # binary, unreadable chdir, etc.) into a sentinel exit code so the
    # parallel reaper never blocks waiting for a fiber that crashed.
    private def run_one(cmd : String, args : Array(String), path : String, *, attach_stdin : Bool) : Int32
      # A missing `chdir:` target and a missing *command* both surface as
      # File::NotFoundError, and the runtime's message names the command
      # ("Error executing process: 'true': No such file or directory") —
      # so a deleted tagged directory looks like the user mistyped a
      # binary that plainly exists. Check the directory first and say what
      # actually went wrong, pointing at the cleanup command for dead paths.
      unless Dir.exists?(path)
        STDERR.puts "✗ #{path}: directory no longer exists (run `doma prune --gone` to drop dead paths)"
        return 127
      end
      input = attach_stdin ? STDIN : Process::Redirect::Close
      status = Process.run(cmd, args: args, chdir: path, output: STDOUT, error: STDERR, input: input)
      status.exit_code
    rescue ex : File::NotFoundError
      STDERR.puts "✗ #{path}: #{ex.message}"
      127
    rescue ex : File::AccessDeniedError | RuntimeError | IO::Error
      STDERR.puts "✗ #{path}: #{ex.message}"
      126
    end

    private def announce(path : String, code : Int32, color : Bool, no_header : Bool)
      if code == 0
        # In --no-header mode, success is silent so single-line commands
        # like `pwd` aren't drowned out by 2:1 chrome. Failures still
        # surface so a partial sweep can't slip past the user.
        return if no_header
        msg = "✓ #{path} (exit 0)"
        STDERR.puts(color ? msg.colorize(:green).to_s : msg)
      else
        msg = "✗ #{path} (exit #{code})"
        STDERR.puts(color ? msg.colorize(:red).to_s : msg)
      end
    end
  end
end
