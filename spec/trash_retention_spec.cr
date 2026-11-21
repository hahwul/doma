require "./spec_helper"

describe "Trash retention" do
  it "keeps new snapshots readable after an unterminated record" do
    with_temp_db do |db|
      now = Time.utc.to_unix
      previous = Doma::Trash::Entry.new(now, "0000001", "/previous", "previous", 0_i64, [] of String, {} of String => Int64)
      db.add("/next", ["keep"], validate_path: false)
      snapshot = Doma::Trash.snapshot(db, "/next") || raise "expected a trash snapshot"

      {
        previous.to_json => [snapshot, previous],
        "{\"path\":"     => [snapshot],
      }.each do |tail, expected|
        File.write(Doma::Trash.file_path, tail)
        Doma::Trash.add!(snapshot)
        Doma::Trash.entries.should eq(expected)
      end
    end
  end

  it "prunes expired records when a new entry is trashed" do
    with_temp_db do |_|
      now = Time.utc.to_unix
      expired = Doma::Trash::Entry.new(now - Doma::Trash::DEFAULT_RETENTION_SECONDS - 60, "0000001", "/expired", "expired", 0_i64, [] of String, {} of String => Int64)
      recent = Doma::Trash::Entry.new(now - 60, "0000002", "/recent", "recent", 0_i64, [] of String, {} of String => Int64)
      newest = Doma::Trash::Entry.new(now, "0000003", "/newest", "newest", 0_i64, [] of String, {} of String => Int64)
      File.write(Doma::Trash.file_path, "#{expired.to_json}\n#{recent.to_json}\n")

      Doma::Trash.add!(newest)

      File.read_lines(Doma::Trash.file_path).map { |line| Doma::Trash::Entry.from_json(line).path }
        .should eq([recent.path, newest.path])
    end
  end
end
