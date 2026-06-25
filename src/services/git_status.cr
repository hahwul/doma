module Doma
  # Probes a directory's git working-tree state by spawning
  # `git status --porcelain=v2 --branch` once per directory.
  #
  # Unlike GitDetector — which parses `.git/config` by hand and never
  # spawns a subprocess, because auto-tagging runs on every `add` and a
  # static binary shouldn't fork git for that — this service deliberately
  # shells out. `status` is an explicit, on-demand command; calling the
  # user's own `git` at runtime is not a linked dependency, so the single
  # static binary stays dependency-free. Callers should confirm git is on
  # PATH once up front (see `.available?`) so a missing binary surfaces as
  # one clear error instead of N "not a git repo" rows.
  #
  # Never raises: a non-repo, an unreadable tree, or a vanished git binary
  # all come back as a Status with `git == false`.
  module GitStatus
    extend self

    record Status,
      git : Bool,
      branch : String?,
      upstream : String?,
      detached : Bool,
      ahead : Int32,
      behind : Int32,
      # `modified` counts tracked files with any change (one per path);
      # `staged`/`unstaged` are overlapping subsets of it (a file can be
      # both), so they're for detail, not for summing.
      modified : Int32,
      staged : Int32,
      unstaged : Int32,
      untracked : Int32,
      conflicts : Int32 do
      # Distinct changed paths in the working tree. modified/untracked/
      # conflicts each count one line (= one path) and never overlap, so
      # the sum is a true file count — unlike staged+unstaged, which can
      # double-count a partially-staged file.
      def dirty : Int32
        modified + untracked + conflicts
      end

      def clean? : Bool
        git && dirty == 0
      end

      # True only when there's an upstream to compare against AND the
      # branch has diverged from it. A no-upstream branch reports false
      # (nothing to be ahead/behind *of*), matching how the renderer
      # leaves the ahead/behind column blank in that case.
      def diverged? : Bool
        !upstream.nil? && (ahead > 0 || behind > 0)
      end
    end

    NON_GIT = Status.new(false, nil, nil, false, 0, 0, 0, 0, 0, 0, 0)

    # Whether `git` is callable. Checked once by the command before the
    # parallel sweep so "git not installed" is reported as a single
    # actionable error rather than every directory reading as a non-repo.
    def available? : Bool
      !Process.find_executable("git").nil?
    end

    def probe(path : String) : Status
      output = IO::Memory.new
      status = Process.run(
        "git",
        args: ["-C", path, "status", "--porcelain=v2", "--branch"],
        output: output,
        error: Process::Redirect::Close,
        input: Process::Redirect::Close,
      )
      # git exits non-zero (128) outside a work tree; 0 for both clean
      # and dirty repos. So success? cleanly separates repo from non-repo.
      return NON_GIT unless status.success?
      parse(output.to_s)
    rescue File::NotFoundError
      # git vanished from PATH between the up-front check and here.
      # Degrade rather than crash a parallel worker mid-sweep.
      NON_GIT
    rescue IO::Error
      NON_GIT
    end

    # Pure parser over `--porcelain=v2 --branch` output. Split out from
    # the spawn so the parsing logic is unit-testable without a real repo.
    #
    # Header lines (one field each):
    #   # branch.head  <name>       — "(detached)" when no branch
    #   # branch.upstream <name>    — absent when no upstream is set
    #   # branch.ab  +<ahead> -<behind>
    # Entry lines:
    #   1 <XY> ...  ordinary change   — X=staged col, Y=unstaged col, '.'=clean
    #   2 <XY> ...  renamed/copied    — same XY semantics
    #   u  ...      unmerged (conflict)
    #   ?  ...      untracked
    #   !  ...      ignored (never emitted without --ignored; skipped anyway)
    def parse(output : String) : Status
      branch : String? = nil
      upstream : String? = nil
      detached = false
      ahead = 0
      behind = 0
      modified = 0
      staged = 0
      unstaged = 0
      untracked = 0
      conflicts = 0

      output.each_line do |raw|
        line = raw.chomp
        next if line.empty?

        if line.starts_with?("# branch.")
          key, _, val = line[2..].partition(' ')
          case key
          when "branch.head"
            if val == "(detached)"
              detached = true
            else
              branch = val
            end
          when "branch.upstream"
            upstream = val unless val.empty?
          when "branch.ab"
            # e.g. "+2 -1" → ahead 2, behind 1.
            val.split(' ') do |tok|
              if tok.starts_with?('+')
                ahead = tok[1..].to_i? || 0
              elsif tok.starts_with?('-')
                behind = tok[1..].to_i? || 0
              end
            end
          end
          next
        end
        next if line.starts_with?('#')

        case line[0]?
        when '1', '2'
          modified += 1
          # Porcelain v2 fixes the 2-char XY field at a known offset:
          # "1 XY …" / "2 XY …" → X at index 2, Y at index 3. Read those
          # directly instead of splitting the whole line into ~9 tokens;
          # this runs once per changed file across the whole sweep.
          # X != '.' → staged, Y != '.' → unstaged (a file can be both).
          x = line[2]?
          y = line[3]?
          if x && y
            staged += 1 if x != '.'
            unstaged += 1 if y != '.'
          end
        when 'u'
          conflicts += 1
        when '?'
          untracked += 1
        end
      end

      Status.new(true, branch, upstream, detached, ahead, behind, modified, staged, unstaged, untracked, conflicts)
    end
  end
end
