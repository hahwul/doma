require "./spec_helper"

private def entry(path : String, tags : Array(String) = [] of String, short_id : String = "abc1234", id : Int64 = 1_i64)
  Doma::Entry.new(id, short_id, path, File.basename(path), tags)
end

describe Doma::TUI::Query do
  describe ".parse" do
    it "parses a tag: token into an include filter" do
      parsed = Doma::TUI::Query.parse("tag:crystal")
      parsed.tag_includes.should eq(["crystal"])
      parsed.terms.should be_empty
    end

    it "ANDs repeated tag: tokens" do
      parsed = Doma::TUI::Query.parse("tag:a tag:b")
      parsed.tag_includes.should eq(["a", "b"])
    end

    it "splits tag: filters from free fuzzy terms" do
      parsed = Doma::TUI::Query.parse("tag:crystal api")
      parsed.tag_includes.should eq(["crystal"])
      parsed.terms.map(&.text).should eq(["api"])
    end

    it "parses -tag: and !tag: as exclusions" do
      parsed = Doma::TUI::Query.parse("-tag:foo !tag:bar")
      parsed.tag_excludes.should eq(["foo", "bar"])
    end

    it "parses id: (lowercased) and path: terms" do
      parsed = Doma::TUI::Query.parse("id:0DC path:src")
      parsed.id_prefixes.should eq(["0dc"])
      parsed.terms.size.should eq(1)
      parsed.terms.first.path_only.should be_true
    end

    it "treats a bare tag: / unknown prefix as ignorable / a free term" do
      parsed = Doma::TUI::Query.parse("tag: foo:bar baz")
      parsed.tag_includes.should be_empty
      parsed.terms.map(&.text).should eq(["foo:bar", "baz"])
    end

    it "reports an all-empty parse as empty" do
      Doma::TUI::Query.parse("   ").empty?.should be_true
    end
  end

  describe ".filter" do
    entries = [
      entry("/p/doma", ["crystal", "cli"], "aaa0001", 1_i64),
      entry("/p/domain-api", ["crystal", "web"], "bbb0002", 2_i64),
      entry("/p/notes", ["personal"], "ccc0003", 3_i64),
    ]

    it "returns every entry (score 0) for an empty query, preserving order" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse(""))
      result.size.should eq(3)
      result.all? { |s| s.score == 0 }.should be_true
      result.map(&.entry.path).should eq(["/p/doma", "/p/domain-api", "/p/notes"])
    end

    it "gates by an include tag (glob via TagGlob)" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse("tag:crystal"))
      result.map(&.entry.path).sort!.should eq(["/p/doma", "/p/domain-api"])
    end

    it "drops entries matching an exclude tag" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse("tag:crystal -tag:web"))
      result.map(&.entry.path).should eq(["/p/doma"])
    end

    it "gates by short-id prefix" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse("id:bbb"))
      result.map(&.entry.path).should eq(["/p/domain-api"])
    end

    it "ANDs fuzzy terms and drops non-matches" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse("doma"))
      # Both /p/doma and /p/domain-api fuzzy-match 'doma'; notes does not.
      paths = result.map(&.entry.path)
      paths.should contain("/p/doma")
      paths.should contain("/p/domain-api")
      paths.should_not contain("/p/notes")
    end

    it "ranks the basename match first" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse("doma"))
      result.first.entry.path.should eq("/p/doma")
    end

    it "combines a tag gate with a fuzzy term" do
      result = Doma::TUI::Query.filter(entries, Doma::TUI::Query.parse("tag:web api"))
      result.map(&.entry.path).should eq(["/p/domain-api"])
    end
  end
end
