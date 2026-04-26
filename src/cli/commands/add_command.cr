require "option_parser"
require "../../db/database"
require "../../services/git_detector"
require "../../utils/config"
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
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: doma add [<path> ...] [-t TAG ...] [--auto-tag] [--git-tag] [--dry-run]"
        p.on("-t TAG", "--tag=TAG", "Add a tag (repeatable, comma-separated allowed)") do |t|
          raw_tags << t
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

      # Dry-run path: resolve everything but never open a writable db.
      # Done as a separate branch (rather than a flag inside the loop)
      # because there's no point even touching the database for a preview.
      if dry_run
        failures = process_each(positional) do |path|
          abs = Doma::Validator.path!(path)
          applied = Doma::Validator.tags!(raw_tags).dup
          applied.concat(derive_tags(abs, use_basename, use_git))
          applied.uniq!
          summary = applied.empty? ? "(no tags)" : "tags: #{applied.join(", ")}"
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
          applied.concat(derive_tags(abs, use_basename, use_git))
          applied.uniq!

          db.add(abs, applied, validate_path: false)

          summary = applied.empty? ? "(no tags)" : "tags: #{applied.join(", ")}"
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
          Doma::Logger.error "#{path}: #{ex.message}"
        end
      end
      failures
    end

    private def derive_tags(abs : String, use_basename : Bool, use_git : Bool) : Array(String)
      sources = [] of String
      sources << File.basename(abs) if use_basename
      sources.concat(Doma::GitDetector.detect(abs).to_tags) if use_git
      sources.compact_map { |raw| Doma::Validator.sanitize_tag(raw) }
    end
  end
end
