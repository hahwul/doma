require "option_parser"
require "colorize"
require "../../db/database"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/suggester"

module Doma::CLI
  # Runs a shell command in every directory matching the given tag.
  #
  #   doma run <tag> -- <cmd> [args...]
  class RunCommand
    def run(args : Array(String))
      stop_on_fail = false
      parallel = false
      no_header = false
      tag_args = [] of String
      cmd_args = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma run <tag> [--fail-fast] [--parallel] [--no-header] -- <cmd> [args...]"
        p.on("--fail-fast", "Stop on first failure") { stop_on_fail = true }
        p.on("--parallel", "Run commands in parallel (best-effort, output interleaves)") { parallel = true }
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
      # Global -q already implies --no-header — both want a quieter run.
      no_header ||= Doma::Logger.quiet?

      raise Doma::ValidationError.new("tag is required") if tag_args.empty?
      raise Doma::ValidationError.new("command is required after '--'") if cmd_args.empty?

      tag = tag_args.first
      db = Doma::Database.open
      paths, all_tags = begin
        {db.paths_for_tag(tag), db.tag_names}
      ensure
        db.close
      end

      if paths.empty?
        raise Doma::NotFoundError.new(
          "no directories tagged '#{tag}'",
          hint: Doma::Suggester.hint_for(tag, all_tags)
        )
      end

      cmd = cmd_args.first
      cmd_rest = cmd_args[1..]
      color = Doma::Logger.color_enabled?
      failures = 0

      if parallel
        Doma::Logger.warn "--fail-fast is ignored in --parallel mode" if stop_on_fail
        channels = paths.map do |path|
          ch = Channel({String, Int32}).new
          spawn do
            code = run_one(cmd, cmd_rest, path, attach_stdin: false)
            ch.send({path, code})
          end
          ch
        end
        channels.each do |ch|
          path, code = ch.receive
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
