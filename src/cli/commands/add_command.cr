require "option_parser"
require "../../db/database"
require "../../services/git_detector"
require "../../utils/config"
require "../../utils/duration"
require "../../utils/errors"
require "../../utils/logger"
require "../../utils/validator"

module Doma::CLI
  class AddCommand
    def run(args : Array(String))
      raw_tags = [] of String
      auto_basename : Bool? = nil
      auto_git : Bool? = nil
      dry_run = false
      expires_at : Int64? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma add [<path> ...] [-t TAG ...] [--ttl DUR | --tmp] [--auto-tag] [--git-tag] [--dry-run]"
        p.on("-t TAG", "--tag=TAG", "Add a tag (repeatable, comma-separated allowed)") do |t|
          raw_tags << t
        end
        # `--ttl DUR` and `--tmp` are mutually exclusive in spirit; if
        # both are passed the last one wins, which is the same lenient
        # behavior we use for other repeated flags.
        p.on("--ttl DUR", "Tag expires after DUR (e.g. 30m, 1h, 7d, 2w)") do |dur|
          expires_at = Doma::Duration.expires_at_for(dur)
        end
        p.on("--tmp", "Tag expires in 7d (alias for --ttl 7d)") do
          expires_at = Doma::Duration.default_tmp_expires_at
        end
        p.on("--auto-tag", "Use the directory basename as a tag") { auto_basename = true }
        p.on("--no-auto-tag", "Disable basename auto-tag (override config)") { auto_basename = false }
        p.on("--git-tag", "Detect a git remote and add host/repo tags") { auto_git = true }
        p.on("--no-git-tag", "Disable git auto-tag (override config)") { auto_git = false }
        p.on("-n", "--dry-run", "Show what would happen without writing") { dry_run = true }
        p.on("-h", "--help", "Show help") do
          puts p
          exit 0
        end
        p.unknown_args do |before, after|
          positional.concat(before)
          positional.concat(after)
        end
      end
      parser.parse(args)

      # Default to the current directory when no path is given. This is
      # the typical "I'm in the dir I want to tag" flow — `cd ~/proj &&
      # doma add -t crystal` with no path argument should Just Work.
      positional << "." if positional.empty?

      cfg = Doma::Settings.current
      # `!!` collapses `Bool?` into a real `Bool` after the nil check —
      # Crystal's type inference doesn't always narrow through ternaries on
      # ivars/closures, and the nilable type leaks into method signatures
      # otherwise.
      use_basename : Bool = auto_basename.nil? ? cfg.auto_tag.basename : !!auto_basename
      use_git : Bool = auto_git.nil? ? cfg.auto_tag.git : !!auto_git

      ttl_label = expires_at.try { |e| "expires #{Time.unix(e).to_local.to_s("%Y-%m-%d %H:%M")}" }

      # `auto_git == true` only when the user passed `--git-tag` explicitly;
      # config-driven on stays nil → !!auto_git just collapses to a Bool.
      # We track the explicit form separately so we can warn under -v when
      # the flag had no effect (non-git directory) — staying silent for
      # config-on auto-tagging, which is meant to be magic.
      git_explicit = auto_git == true

      # Dry-run path: resolve everything but never open a writable db.
      # Done as a separate branch (rather than a flag inside the loop)
      # because there's no point even touching the database for a preview.
      if dry_run
        failures = process_each(positional) do |path|
          abs = Doma::Validator.path!(path)
          applied = Doma::Validator.tags!(raw_tags).dup
          applied.concat(derive_tags(abs, use_basename, use_git, git_explicit))
          applied.uniq!
          summary = applied.empty? ? "(no tags)" : "tags: #{applied.join(", ")}"
          summary += "  (#{ttl_label})" if ttl_label
          Doma::Logger.info "[dry-run] would add #{abs} #{summary}"
        end
        exit 2 if failures > 0
        return
      end

      db = Doma::Database.open
      begin
        failures = process_each(positional) do |path|
          abs = Doma::Validator.path!(path)

          # User-supplied tags must validate strictly; auto-derived tags
          # (basename, git remote) flow through `sanitize_tag` so a repo
          # named `.dotfiles` doesn't blow up the whole `add`.
          applied = Doma::Validator.tags!(raw_tags).dup
          applied.concat(derive_tags(abs, use_basename, use_git, git_explicit))
          applied.uniq!

          db.add(abs, applied, validate_path: false, expires_at: expires_at)

          summary = applied.empty? ? "(no tags)" : "tags: #{applied.join(", ")}"
          summary += "  (#{ttl_label})" if ttl_label
          Doma::Logger.success "added #{abs} #{summary}"
        end
        # Non-zero exit when at least one path failed, so scripts can tell.
        # Successful paths are still committed — partial success is the
        # right default for batch add.
        exit 2 if failures > 0
      ensure
        db.close
      end
    end

    # Run the block once per path, catching ValidationError so a single
    # bad input doesn't abort the rest of the batch. Returns the failure
    # count so the caller can pick a non-zero exit code if needed.
    private def process_each(paths : Array(String), &)
      failures = 0
      paths.each do |path|
        begin
          yield path
        rescue ex : Doma::ValidationError
          failures += 1
          Doma::Logger.error format_failure(path, ex, paths.size)
        end
      end
      failures
    end

    # Avoid `<input>: not a directory: <input>` duplication. The
    # validator already names the path in its "not a directory: …"
    # / "path exceeds …" messages; prepending the input again is
    # noise. For multi-path batches we still want the input prefix
    # on errors that *don't* already mention it (e.g. tag-validation
    # failures), so the user can tell which path failed.
    private def format_failure(path : String, ex : Exception, batch_size : Int32) : String
      message = ex.message.to_s
      return message if batch_size <= 1
      return message if message.ends_with?(": #{path}")
      "#{path}: #{message}"
    end

    private def derive_tags(abs : String, use_basename : Bool, use_git : Bool, git_explicit : Bool) : Array(String)
      sources = [] of String
      sources << File.basename(abs) if use_basename
      if use_git
        info = Doma::GitDetector.detect(abs)
        if info.git
          sources.concat(info.to_tags)
        elsif git_explicit
          # The user asked for git tags out loud — surface the no-op in
          # `-v` so they aren't left wondering why the flag did nothing.
          # Stay silent for config-driven auto-tag: that path is meant
          # to be unobtrusive on non-git directories.
          Doma::Logger.debug "--git-tag had no effect: #{abs} is not a git working tree"
        end
      end
      sources.compact_map { |raw| Doma::Validator.sanitize_tag(raw) }
    end
  end
end
