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

  it "splits a merge into added (new) vs updated (already present)" do
    with_temp_db do |db|
      # One path already in the db, one brand new in the snapshot.
      existing = Dir.current
      db.add(existing, ["here"])

      snapshot = Doma::Snapshot.new([
        Doma::Snapshot::Entry.new(existing, ["here"]),
        Doma::Snapshot::Entry.new("/imported/fresh", ["new"]),
      ])
      path = File.tempname("doma-snap-split") + ".json"
      File.write(path, snapshot.to_json)
      begin
        result = Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Merge)
        result.imported.should eq(2)
        result.added.should eq(1)
        result.updated.should eq(1)
        result.skipped.should eq(0)

        # A second merge of the same snapshot adds nothing new.
        again = Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Merge)
        again.added.should eq(0)
        again.updated.should eq(2)
        again.imported.should eq(2)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "counts replace-mode entries as added (db was wiped first)" do
    with_temp_db do |db|
      db.add(Dir.current, ["old"])
      snapshot = Doma::Snapshot.new([
        Doma::Snapshot::Entry.new("/imported/path", ["imported"]),
      ])
      path = File.tempname("doma-snap-replace") + ".json"
      File.write(path, snapshot.to_json)
      begin
        result = Doma::Importer.from_file(db, path, mode: Doma::Importer::Mode::Replace)
        result.added.should eq(1)
        result.updated.should eq(0)
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

  it "registers an entry with an empty tags array (no silent no-op)" do
    # Regression: when v2 grouping-by-TTL was introduced, an empty tags
    # array meant the inner loop never invoked add_tx, so the importer
    # reported `imported: 1` while leaving the database untouched.
    with_temp_db do |db|
      payload = %({"version":2,"entries":[{"path":"/imported/empty","tags":[]}]})
      path = File.tempname("doma-empty-tags") + ".json"
      File.write(path, payload)
      begin
        result = Doma::Importer.from_file(db, path)
        result.imported.should eq(1)
        rows = db.directories
        rows.size.should eq(1)
        rows.first.tags.should be_empty
      ensure
        File.delete(path) if File.exists?(path)
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

  it "rejects a directory passed as the import file" do
    # File.file?() is false for directories, so the importer's existence
    # guard fires before the parser ever sees the input. Without this
    # check, `from_file` would walk the path and surface a confusing
    # IO::Error from `File.read`.
    with_temp_db do |db|
      dir = File.tempname("doma-import-dir")
      FileUtils.mkdir_p(dir)
      begin
        expect_raises(Doma::ImportError, /not found/) do
          Doma::Importer.from_file(db, dir)
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "labels parser errors with the source path" do
    # b7e3f56 / 639a5a0: the file path should appear in malformed-snapshot
    # errors so the user can tell *which* file blew up when they're
    # importing several at once.
    with_temp_db do |db|
      path = File.tempname("doma-bad-snap") + ".json"
      File.write(path, "{not valid json")
      begin
        ex = expect_raises(Doma::ImportError) do
          Doma::Importer.from_file(db, path)
        end
        msg = ex.message || ""
        msg.should contain("invalid JSON")
        msg.should contain(path)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "format-detects by extension over content sniffing — .json with YAML body fails as JSON" do
    # Without extension preference, a YAML-shaped body with no leading
    # `{`/`[` would silently route to the YAML parser even though the
    # filename promised JSON. The user gets a misleading parser label.
    with_temp_db do |db|
      path = File.tempname("doma-mismatch") + ".json"
      # Pure YAML mapping; valid YAML, definitely not valid JSON.
      File.write(path, "version: 1\nentries: []\n")
      begin
        expect_raises(Doma::ImportError, /invalid JSON/) do
          Doma::Importer.from_file(db, path)
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "format-detects by extension — .yml with JSON-rejecting content fails as YAML" do
    with_temp_db do |db|
      path = File.tempname("doma-mismatch") + ".yml"
      # Tab-indented mapping — illegal under YAML's whitespace rules.
      File.write(path, "version: 1\nentries:\n\t- bad\n")
      begin
        expect_raises(Doma::ImportError, /invalid YAML/) do
          Doma::Importer.from_file(db, path)
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "skips entries that fail validation and counts them in result.skipped" do
    # The importer's per-entry rescue branch is what keeps a single bad
    # row from torpedoing an otherwise-valid snapshot. Pre-fix, no spec
    # explicitly verified `result.skipped` reflected the count.
    with_temp_db do |db|
      payload = <<-JSON
        {
          "version": 2,
          "entries": [
            {"path": "/valid/path", "tags": ["ok"]},
            {"path": "/another/valid", "tags": ["bad name"]},
            {"path": "/third", "tags": ["fine"]}
          ]
        }
        JSON
      path = File.tempname("doma-mixed-snap") + ".json"
      File.write(path, payload)
      begin
        result = Doma::Importer.from_file(db, path)
        # Two valid + one rejected by the tag validator (whitespace).
        result.imported.should eq(2)
        result.skipped.should eq(1)
        # The rejected entry's path must not show up in the DB.
        db.directories.map(&.path).should_not contain("/another/valid")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end

describe Doma::Exporter do
  it "stamps the snapshot with version + generated_at" do
    with_temp_db do |db|
      before = Time.utc.to_unix
      snapshot = Doma::Exporter.build(db)
      after = Time.utc.to_unix

      snapshot.version.should eq(Doma::Snapshot::SCHEMA_VERSION)
      snapshot.generated_at.should_not be_nil
      ts = snapshot.generated_at.as(Int64)
      (before..after).covers?(ts).should be_true
    end
  end

  it "omits the expirations field on entries with only permanent tags" do
    # Snapshot::Entry uses `emit_null: false` so a permanent-only entry
    # serializes the same as a v1 snapshot — keeps round-trip output
    # visually identical for the common case.
    with_temp_db do |db|
      tmp = File.tempname("doma-exp-perm")
      FileUtils.mkdir_p(tmp)
      begin
        db.add(tmp, ["forever"]) # no TTL
        io = IO::Memory.new
        Doma::Exporter.write(db, Doma::Exporter::Format::Json, io)
        json = io.to_s
        # The field must not appear at all — `"expirations": null` would
        # also be wrong (importer treats absence as "all permanent").
        json.should_not contain("expirations")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  it "emits expirations only for tags with a future TTL" do
    with_temp_db do |db|
      tmp = File.tempname("doma-exp-mixed")
      FileUtils.mkdir_p(tmp)
      begin
        future = Time.utc.to_unix + 7 * 86_400
        db.add(tmp, ["bookmark"], expires_at: future)
        db.add(tmp, ["permanent"]) # different call → permanent

        snapshot = Doma::Exporter.build(db)
        entry = snapshot.entries.first
        entry.expirations.should_not be_nil
        ttls = entry.expirations.as(Hash(String, Int64))
        ttls.has_key?("bookmark").should be_true
        ttls.has_key?("permanent").should be_false
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end
