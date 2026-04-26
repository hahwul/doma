# Benchmark harness for doma's hot paths. Run with:
#
#   crystal run --release bench/bench.cr
#
# Seeds an in-memory-ish temp DB with realistic-ish sizes, then times the
# operations users hit on every command. Print only — no assertions —
# because the goal is to track regressions, not gate CI.

require "file_utils"
require "../src/doma"

SCALE_DIRECTORIES  = 1000
SCALE_TAGS         =   60
SCALE_TAGS_PER_DIR =    3

def with_seeded_db(&)
  dir = File.tempname("doma-bench")
  FileUtils.mkdir_p(dir)
  db_path = File.join(dir, "doma.db")
  db = Doma::Database.open(db_path)
  begin
    seed(db)
    yield db
  ensure
    db.close
    FileUtils.rm_rf(dir)
  end
end

def seed(db : Doma::Database)
  rng = Random.new(42)
  tag_pool = Array(String).new(SCALE_TAGS) { |i| "tag-#{i}" }
  SCALE_DIRECTORIES.times do |i|
    tags = Array(String).new(SCALE_TAGS_PER_DIR) { tag_pool[rng.rand(tag_pool.size)] }
    db.add("/tmp/doma-bench/dir-#{i}", tags.uniq!, validate_path: false)
  end
end

def time(label : String, runs : Int32 = 3, &)
  durations = Array(Time::Span).new(runs)
  result = nil
  runs.times do
    elapsed = Time.measure { result = yield }
    durations << elapsed
  end
  best = durations.min
  worst = durations.max
  median = durations.sort![durations.size // 2]
  puts "  %-32s best=%-9s median=%-9s worst=%-9s" % [
    label,
    fmt(best),
    fmt(median),
    fmt(worst),
  ]
end

def fmt(span : Time::Span) : String
  ms = span.total_milliseconds
  case
  when ms < 1   then "%.2fms" % ms
  when ms < 100 then "%.1fms" % ms
  else               "%.0fms" % ms
  end
end

puts "doma bench — #{SCALE_DIRECTORIES} dirs × #{SCALE_TAGS} tags (#{SCALE_TAGS_PER_DIR} per dir)"
puts ""

with_seeded_db do |db|
  puts "Listing operations:"
  time("directories() — no filter") { db.directories.size }
  time("directories('tag-3')") { db.directories("tag-3").size }
  time("directories(sort: Recent)") { db.directories(sort: Doma::Database::SortBy::Recent).size }
  time("paths_for_tag('tag-3')") { db.paths_for_tag("tag-3").size }
  time("paths_for_tag('tag-*') glob") { db.paths_for_tag("tag-*").size }
  time("search('dir-9')") { db.search("dir-9").size }

  puts ""
  puts "Aggregate operations:"
  time("all_tags") { db.all_tags.size }
  time("stats(top=10, recent=5, used=5)") { db.stats }
  time("dead_paths") { db.dead_paths.size }
  time("tag_names") { db.tag_names.size }
end
