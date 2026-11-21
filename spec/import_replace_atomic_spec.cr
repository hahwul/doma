require "./spec_helper"

describe "Snapshot replacement atomicity" do
  [false, true].each do |dry_run|
    it "rejects an invalid entry with dry_run=#{dry_run} and preserves existing data" do
      with_temp_db do |db|
        db.add("/original", ["keep"], validate_path: false)
        original = db.directories.first
        snapshot = File.join(Doma::Config.home, "replace.json")
        File.write(snapshot, <<-JSON)
          {"version":2,"entries":[
            {"path":"/replacement","tags":["valid"]},
            {"path":"relative/path","tags":["invalid"]}
          ]}
          JSON

        expect_raises(Doma::ImportError, /relative\/path/) do
          Doma::Importer.from_file(db, snapshot, mode: Doma::Importer::Mode::Replace, dry_run: dry_run)
        end
        db.directories.map(&.short_id).should eq([original.short_id])
        db.directories.first.tags.should eq(["keep"])
      end
    end
  end
end
