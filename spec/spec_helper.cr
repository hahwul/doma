require "spec"
require "file_utils"
require "../src/doma"

# Each spec gets a fresh sqlite file under a tmp dir so they can run in parallel
# without trampling each other's state.
def with_temp_db(&)
  dir = File.tempname("doma-spec")
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "doma.db")
  begin
    yield Doma::Database.open(path)
  ensure
    FileUtils.rm_rf(dir)
  end
end
