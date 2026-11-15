require "spec"
require "file_utils"
require "../src/doma"

# CLI specs spawn bin/doma, which inherits this process's ENV. A DOMA_DB or
# DOMA_CONFIG exported in the developer's shell would win over the per-spec
# DOMA_HOME and point the suite at their real database, so drop every
# state-changing override before any spec runs.
%w[DOMA_DB DOMA_CONFIG DOMA_YES DOMA_CD_FILE].each { |k| ENV.delete(k) }

# What `/tmp` canonicalizes to: `/private/tmp` on macOS, `/tmp` on Linux.
REAL_TMP = File.realpath("/tmp")

# Each spec gets a fresh sqlite file under a tmp dir so they can run in parallel
# without trampling each other's state.
#
# DOMA_HOME is also pointed at that same tmp dir for the duration of the
# block. The db itself is opened from an explicit path, but anything that
# resolves `Doma::Config.home` directly — `Doma::Trash` (trash.jsonl +
# trash.lock) and the cd-hint marker — would otherwise read and write the
# real `~/.config/doma`. That both pollutes the user's actual data when
# the suite runs and makes trash-touching specs non-deterministic (a
# leftover real-world trash entry fails an `eq(1)` assertion). Co-locating
# home with the temp db mirrors production layout and keeps every spec
# fully self-contained.
def with_temp_db(&)
  dir = File.tempname("doma-spec")
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "doma.db")
  prev_home = ENV["DOMA_HOME"]?
  ENV["DOMA_HOME"] = dir
  db = Doma::Database.open(path)
  begin
    yield db
  ensure
    db.close if db
    prev_home ? (ENV["DOMA_HOME"] = prev_home) : ENV.delete("DOMA_HOME")
    FileUtils.rm_rf(dir)
  end
end
