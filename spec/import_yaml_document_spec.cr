require "./spec_helper"

describe "YAML snapshot documents" do
  it "accepts a single marked document with comments" do
    content = "# before\n---\nversion: 2\nentries: []\n...\n# after\n"
    Doma::Importer.parse(content, "snapshot.yml").entries.should be_empty
  end

  it "rejects a snapshot stream without a document" do
    expect_raises(Doma::ImportError, /invalid YAML/) do
      Doma::Importer.parse("# only a comment\n", "snapshot.yml")
    end
  end

  {"another snapshot" => "version: 2\nentries: []", "an empty document" => "", "malformed YAML" => "entries: ["}.each do |description, tail|
    it "preserves the database when a replacement snapshot trails #{description}" do
      with_temp_db do |db|
        db.add("/original", ["keep"], validate_path: false)
        snapshot = File.join(Doma::Config.home, "replace.yml")
        File.write(snapshot, "---\nversion: 2\nentries: []\n---\n#{tail}\n")

        expect_raises(Doma::ImportError, /invalid YAML/) do
          Doma::Importer.from_file(db, snapshot, mode: Doma::Importer::Mode::Replace)
        end
        db.directories.map(&.path).should eq(["/original"])
        db.directories.first.tags.should eq(["keep"])
      end
    end
  end
end
