require "option_parser"
require "json"
require "colorize"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/parallel"
require "../../utils/suggester"
require "../../utils/tag_glob"

module Doma::CLI
  # Runs a shell command in every directory matching the given tag.
  #
  #   doma run <tag> -- <cmd> [args...]
  class RunCommand
    # One directory's outcome. Under `--json` the child's streams are
    # captured into strings so every byte can be attributed to the
    # directory that produced it; in streaming mode the child writes
    # straight through to the terminal and both fields stay empty.
    private record RunResult,
      exit_code : Int32,
      stdout : String,
      stderr : String

    def run(args : Array(String))
      stop_on_fail = false
      parallel = false
      no_header = false
      dry_run = false
      json_mode = false
      jobs : Int32? = nil
      flag_tags = [] of String
      positional_tags = [] of String
      cmd_args = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma run (<tag> | -t TAG) [--fail-fast] [--parallel [--jobs N]] [--no-header] [--dry-run] [--json] -- <cmd> [args...]"
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
        p.on("-n", "--dry-run", "Print the target directories and command without running anything") { dry_run = true }
        p.on("--json", "Capture per-directory output as JSON (one row per directory)") { json_mode = true }
        p.on("-h", "--help", "Show help") do
          puts p
          STDOUT.puts ""
          STDOUT.puts "Runs <cmd> in every directory tagged with <tag>. The tag"
          STDOUT.puts "can be passed positionally (`run work -- cmd`) or via"
          STDOUT.puts "`-t TAG` (`run -t work -- cmd`), but not both. Only a"
          STDOUT.puts "single tag is accepted; glob patterns (`*`, `?`) still"
          STDOUT.puts "match across multiple tags."
          STDOUT.puts ""
          STDOUT.puts "--json captures each child's stdout/stderr instead of"
          STDOUT.puts "streaming them, and emits one row per directory:"
          STDOUT.puts "  [{\"path\":…,\"exit_code\":0,\"stdout\":…,\"stderr\":…,\"dry_run\":false}]"
          STDOUT.puts "Rows keep the input directory order even under --parallel,"
          STDOUT.puts "which is the only way to tell whose output is whose."
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
      # So does --json: the rows carry every exit code, so a parallel ✓/✗
      # stream on stderr would just be a second, less precise report of
      # what stdout already says.
      no_header ||= Doma::Logger.quiet? || json_mode

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
      # Extra positional tags were previously dropped silently — `run work
      # personal -- cmd` swept only `work` while the user believed both
      # sets ran. Reject it the way `status` already does, and point at the
      # glob form for sweeping several tags at once.
      if positional_tags.size > 1
        raise Doma::ValidationError.new(
          "run accepts a single tag; got #{positional_tags.size} positional args",
          hint: "use a glob like 'work*' to sweep several tags in one run"
        )
      end
      tag_args = flag_tags.empty? ? positional_tags : flag_tags

      raise Doma::ValidationError.new("tag is required") if tag_args.empty?

      tag = tag_args.first
      paths, all_tags = Doma::Database.open do |db|
        # Use `directories(tag)` (returns Entry rows with their tag list)
        # rather than `paths_for_tag` so we can post-filter against the
        # strict glob rules. SQL GLOB treats `*` as crossing `/`; we
        # reimpose shell-glob semantics in Crystal so `run 'a/*' -- ...`
        # doesn't end up running in `a/b/c/d`.
        entries = db.directories(tag, sort: Doma::Database::SortBy::Recent)
        entries = Doma::TagGlob.filter(entries, tag, &.tags)
        {entries.map(&.path).uniq!, db.tag_names}
      end

      if paths.empty?
        raise Doma::NotFoundError.new(
          "no directories tagged '#{tag}'",
          hint: Doma::Suggester.tag_hint_for(tag, all_tags)
        )
      end

      # Preview mode: `run <tag> -- <cmd>` fires immediately in every match,
      # so give users a way to *see* the target set (and confirm the glob
      # resolved as intended) before committing to a destructive sweep. The
      # target paths go to stdout, one per line, so a dry-run composes with
      # the rest of the shell exactly like `list --paths`.
      if dry_run
        if json_mode
          # Preview rows carry no exit code — nothing ran. `dry_run` is
          # always present (in both modes) so a consumer can tell a
          # preview from a result without inspecting which keys exist.
          rows = paths.map do |path|
            {"path" => JSON::Any.new(path), "dry_run" => JSON::Any.new(true)}
          end
          puts rows.to_json
          return
        end
        # Summary on STDERR so STDOUT stays pure paths (pipeable like
        # `list --paths`); mirrors where `run` prints its ▶/✓ chrome.
        # Suppressed under -q, which asks for just the machine-readable set.
        unless Doma::Logger.quiet?
          noun = paths.size == 1 ? "directory" : "directories"
          STDERR.puts "[dry-run] would run `#{cmd_args.join(" ")}` in #{paths.size} #{noun} tagged '#{tag}'"
        end
        paths.each { |path| puts path }
        return
      end

      cmd = cmd_args.first
      cmd_rest = cmd_args[1..]
      color = Doma::Logger.color_enabled?
      failures = 0

      # Hoisted above the mode split so the JSON path warns too — the
      # flag is just as inert there.
      Doma::Logger.warn "--fail-fast is ignored in --parallel mode" if parallel && stop_on_fail

      if json_mode
        failures = run_json(paths, cmd, cmd_rest, parallel, jobs, stop_on_fail)
      elsif parallel
        # Bounded fan-out (see Doma::Parallel): without a cap, one fiber
        # per directory is fine for a `pwd` sweep but a foot-gun for
        # `git fetch` / `npm install` — 200 simultaneous network jobs
        # would saturate the user's box. Process.run yields while each
        # child runs, so the capped pool still overlaps real subprocess
        # time. `each_completed` streams a ✓/✗ marker the moment each
        # directory returns and yields on this fiber, so the `failures`
        # tally needs no cross-fiber synchronization.
        # Copy the closured `jobs` into a plain local so Crystal can
        # narrow Int32? → Int32 (a captured var can't be narrowed in place).
        j = jobs
        requested_jobs = j || Doma::Parallel.default_jobs
        Doma::Parallel.each_completed(
          paths, requested_jobs,
          ->(path : String) { run_one(cmd, cmd_rest, path, attach_stdin: false, capture: false).exit_code }
        ) do |path, code|
          announce(path, code, color, no_header)
          failures += 1 unless code == 0
        end
      else
        paths.each do |path|
          unless no_header
            header = "▶ #{path}"
            STDERR.puts(color ? header.colorize(:cyan).bold.to_s : header)
          end
          code = run_one(cmd, cmd_rest, path, attach_stdin: true, capture: false).exit_code
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

    # `--json` sweep: capture each directory's streams and emit one row
    # per directory in INPUT order, so a consumer can attribute every
    # byte to the directory that produced it. That attribution is the
    # whole point of the mode — the streaming path merges N children onto
    # one terminal, and under `--parallel` there is no way left to tell
    # whose line is whose.
    private def run_json(paths : Array(String), cmd : String, cmd_rest : Array(String), parallel : Bool, jobs : Int32?, stop_on_fail : Bool) : Int32
      results = if parallel
                  # `map`, not `each_completed`: it slots each result back
                  # at the item's original index, so out-of-order
                  # completion still produces an input-ordered array.
                  # Nothing here wants live progress — the rows only get
                  # serialized once the whole sweep is in.
                  j = jobs || Doma::Parallel.default_jobs
                  Doma::Parallel.map(paths, j) do |path|
                    run_one(cmd, cmd_rest, path, attach_stdin: false, capture: true)
                  end
                else
                  collected = [] of RunResult
                  paths.each do |path|
                    # stdin stays closed even sequentially: a captured run
                    # is consumed by a machine, so letting a child inherit
                    # the terminal would let it block on input nobody is
                    # watching for.
                    result = run_one(cmd, cmd_rest, path, attach_stdin: false, capture: true)
                    collected << result
                    break if stop_on_fail && result.exit_code != 0
                  end
                  collected
                end

      # `--fail-fast` truncates `results` to a prefix of `paths`, so
      # zipping by index stays correct — the array just ends early, and
      # the missing directories are the ones that never ran.
      rows = results.map_with_index do |result, i|
        {
          "path"      => JSON::Any.new(paths[i]),
          "exit_code" => JSON::Any.new(result.exit_code.to_i64),
          "stdout"    => JSON::Any.new(result.stdout),
          "stderr"    => JSON::Any.new(result.stderr),
          "dry_run"   => JSON::Any.new(false),
        }
      end
      puts rows.to_json
      results.count { |r| r.exit_code != 0 }
    end

    # Runs a single instance, translating spawn/exec failures (missing
    # binary, unreadable chdir, etc.) into a sentinel exit code so the
    # parallel reaper never blocks waiting for a fiber that crashed.
    #
    # `capture` swaps the child's stdout/stderr from the terminal to
    # in-memory buffers; the caller picks based on whether it's about to
    # render JSON or stream.
    private def run_one(cmd : String, args : Array(String), path : String, *, attach_stdin : Bool, capture : Bool) : RunResult
      # A missing `chdir:` target and a missing *command* both surface as
      # File::NotFoundError, and the runtime's message names the command
      # ("Error executing process: 'true': No such file or directory") —
      # so a deleted tagged directory looks like the user mistyped a
      # binary that plainly exists. Check the directory first and say what
      # actually went wrong, pointing at the cleanup command for dead paths.
      unless Dir.exists?(path)
        return fail_result(path, "directory no longer exists (run `doma prune --gone` to drop dead paths)", 127, capture)
      end
      input = attach_stdin ? STDIN : Process::Redirect::Close
      unless capture
        status = Process.run(cmd, args: args, chdir: path, output: STDOUT, error: STDERR, input: input)
        return RunResult.new(status.exit_code, "", "")
      end
      # Fresh buffers per call: under --parallel this method runs on N
      # fibers at once, and a shared sink would splice two children's
      # bytes into one directory's record.
      # Named `out_io`/`err_io` because a bare `out` is a Crystal keyword
      # (the C-binding out-parameter form) and can't be used as an
      # argument value.
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(cmd, args: args, chdir: path, output: out_io, error: err_io, input: input)
      RunResult.new(status.exit_code, out_io.to_s, err_io.to_s)
    rescue ex : File::NotFoundError
      fail_result(path, ex.message || "command not found", 127, capture)
    rescue ex
      # Catch-all, not just the expected spawn failures: under
      # --parallel an unrescued exception kills the worker fiber and the
      # reaper's `results.receive` then blocks forever. A weird failure
      # must degrade to a failed directory, never a hang.
      fail_result(path, ex.message || ex.class.name, 126, capture)
    end

    # A failure with no child streams to report — doma itself is the one
    # explaining what went wrong. In capture mode the reason becomes the
    # row's `stderr` so the JSON consumer learns why the directory
    # failed; otherwise it goes to the terminal in the same ✗ form
    # `announce` uses.
    private def fail_result(path : String, reason : String, code : Int32, capture : Bool) : RunResult
      return RunResult.new(code, "", reason) if capture
      STDERR.puts "✗ #{path}: #{reason}"
      RunResult.new(code, "", "")
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
