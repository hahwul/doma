require "./spec_helper"

describe "Import/Export" do
  it "round-trips a database through JSON" do
    with_temp_db do |db|
      tmp_a = File.tempname("doma-a")
      tmp_b = File.tempname("doma-b")
      FileUtils.mkdir_p(tmp_a)
      FileUtils.mkdir_p(tmp_b)
      begin
        db.add(tmp_a, ["crystal", "cli"])
        db.add(tmp_b, ["python"])

        io = IO::Memory.new
        Doma::Exporter.write(db, Doma::Exporter::Format::Json, io)
        snapshot = Doma::Importer.parse(io.to_s)
        snapshot.entries.size.should eq(2)
        snapshot.version.should eq(Doma::Snapshot::SCHEMA_VERSION)
      ensure
        FileUtils.rm_rf(tmp_a)
        FileUtils.rm_rf(tmp_b)
      end
    end
  end

  it "round-trips a database through YAML" do
    with_temp_db do |db|
      db.add(Dir.current, ["crystal"])

      io = IO::Memory.new
      Doma::Exporter.write(db, Doma::Exporter::Format::Yaml, io)

      with_temp_db do |db2|
        path = File.tempname("doma-snap") + ".yml"
        File.write(path, io.to_s)
        begin
          result = Doma::Importer.from_file(db2, path)
          result.imported.should eq(1)
          result.skipped.should eq(0)
          db2.directories.first.tags.should eq(["crystal"])
        ensure
          File.delete(path) if File.exists?(path)
        end
      end
    end
  end

  it "merges by default (preserves existing rows)" do
    with_temp_db do |db|
      db.add(Dir.current, ["existing"])

      snapshot = Doma::Snapshot.new([
        Doma::Snapshot::Entry.new("/imported/path", ["imported"]),
      ])
      path = File.tempname("doma-snap") + ".json"
      File.write(path, snapshot.to_json)
      begin
        result = Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Merge)
        result.imported.should eq(1)
        result.replaced.should be_false
        db.directories.size.should eq(2)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "wipes existing rows in replace mode" do
    with_temp_db do |db|
      db.add(Dir.current, ["existing"])

      snapshot = Doma::Snapshot.new([
        Doma::Snapshot::Entry.new("/imported/path", ["imported"]),
      ])
      path = File.tempname("doma-snap") + ".json"
      File.write(path, snapshot.to_json)
      begin
        result = Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Replace)
        result.imported.should eq(1)
        result.replaced.should be_true
        paths = db.directories.map(&.path)
        paths.should eq(["/imported/path"])
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "rejects snapshots from a future schema version" do
    payload = %({"version":99,"entries":[]})
    expect_raises(Doma::ImportError, /newer than supported/) do
      with_temp_db do |db|
        path = File.tempname("doma-snap") + ".json"
        File.write(path, payload)
        begin
          Doma::Importer.from_file(db, path)
        ensure
          File.delete(path) if File.exists?(path)
        end
      end
    end
  end

  it "rejects malformed payloads" do
    expect_raises(Doma::ImportError, /malformed/) do
      Doma::Importer.parse("{not valid json or yaml: [")
    end
  end

  it "rejects missing import file" do
    with_temp_db do |db|
      expect_raises(Doma::ImportError, /not found/) do
        Doma::Importer.from_file(db, "/no/such/file.json")
      end
    end
  end

  it "rejects empty file" do
    with_temp_db do |db|
      path = File.tempname("doma-empty") + ".json"
      File.write(path, "")
      begin
        expect_raises(Doma::ImportError, /empty/) do
          Doma::Importer.from_file(db, path)
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "imports an empty entries array as a no-op" do
    with_temp_db do |db|
      db.add(Dir.current, ["original"])
      payload = %({"version":1,"entries":[]})
      path = File.tempname("doma-empty-entries") + ".json"
      File.write(path, payload)
      begin
        result = Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Merge)
        result.imported.should eq(0)
        result.skipped.should eq(0)
        # Original data preserved.
        db.directories.size.should eq(1)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "rejects a JSON object without an entries field" do
    with_temp_db do |db|
      path = File.tempname("doma-no-entries") + ".json"
      File.write(path, %({"version":1}))
      begin
        expect_raises(Doma::ImportError, /malformed/) do
          Doma::Importer.from_file(db, path)
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "round-trips an empty database (export → import → still empty)" do
    with_temp_db do |db|
      io = IO::Memory.new
      Doma::Exporter.write(db, Doma::Exporter::Format::Json, io)

      with_temp_db do |db2|
        snapshot = Doma::Importer.parse(io.to_s)
        snapshot.entries.should be_empty
        db2.directories.should be_empty
      end
    end
  end

  it "snapshot entries default to an empty tags array (Snapshot::Entry default)" do
    e = Doma::Snapshot::Entry.new("/some/path", [] of String)
    e.tags.should be_empty
    e.path.should eq("/some/path")
  end

  it "preserves per-tag TTLs across an export → import round-trip" do
    # Pre-fix: Snapshot::Entry had no `expirations` field, so a tag with
    # `--ttl 7d` came back as permanent on the importing side.
    with_temp_db do |db|
      tmp = File.tempname("doma-ttl-roundtrip")
      FileUtils.mkdir_p(tmp)
      begin
        future = Time.utc.to_unix + 7 * 86_400
        db.add(tmp, ["bookmark"], expires_at: future)
        db.add(tmp, ["permanent"]) # different call → no TTL

        io = IO::Memory.new
        Doma::Exporter.write(db, Doma::Exporter::Format::Json, io)

        with_temp_db do |db2|
          path = File.tempname("doma-ttl-snap") + ".json"
          File.write(path, io.to_s)
          begin
            Doma::Importer.from_file(db2, path)
            ttls = db2.tag_expirations(db2.directories.first.id)
            ttls["bookmark"].should be_close(future, 5)
            ttls.has_key?("permanent").should be_false
          ensure
            File.delete(path) if File.exists?(path)
          end
        end
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "still accepts v1 snapshots without an expirations field" do
    with_temp_db do |db|
      payload = %({"version":1,"entries":[{"path":"/legacy/path","tags":["legacy"]}]})
      path = File.tempname("doma-v1-snap") + ".json"
      File.write(path, payload)
      begin
        result = Doma::Importer.from_file(db, path)
        result.imported.should eq(1)
        # Tags survive; nothing is mistakenly TTL'd.
        first = db.directories.first
        first.tags.should eq(["legacy"])
        db.tag_expirations(first.id).should be_empty
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end
