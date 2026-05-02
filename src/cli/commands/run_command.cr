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
      tag_args = [] of String
      cmd_args = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma run <tag> [--fail-fast] [--parallel [--jobs N]] [--no-header] -- <cmd> [args...]"
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
          exit 0
        end
        p.unknown_args do |before, after|
          tag_args.concat(before)
          cmd_args.concat(after)
        end
      end
      parser.parse(args)
      if jobs && !parallel
        raise Doma::ValidationError.new("--jobs requires --parallel")
      end
      # Global -q already implies --no-header — both want a quieter run.
      no_header ||= Doma::Logger.quiet?

      raise Doma::ValidationError.new("tag is required") if tag_args.empty?
      raise Doma::ValidationError.new("command is required after '--'") if cmd_args.empty?

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

    # Runs a single instance, translating spawn/exec failures (missing
    # binary, unreadable chdir, etc.) into a sentinel exit code so the
    # parallel reaper never blocks waiting for a fiber that crashed.
    private def run_one(cmd : String, args : Array(String), path : String, *, attach_stdin : Bool) : Int32
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
