require "./spec_helper"

describe "Trash retention" do
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
