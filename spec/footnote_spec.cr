require "./spec_helper"

def strip_ansi(text : String) : String
  text.gsub(/\e\[[0-9;]*[mGKH]/, "")
end

describe "Footnotes" do
  options = Markd::Options.new
  options.gfm = true

  source = "Text with a footnote[^1] and a named one[^note].\n\nMore text with a repeat ref[^1].\n\n[^1]: The first footnote.\n[^note]: A named footnote.\n"

  describe "in terminal output" do
    it "renders references as normalized numbers" do
      result = Markd.to_term(source, options)
      visible = strip_ansi(result)
      visible.should contain("[1]")
      visible.should contain("[2]")
      # The label itself is not shown inline
      visible.should_not contain("[note]")
    end

    it "reuses the number for repeated references" do
      result = Markd.to_term(source, options)
      visible = strip_ansi(result)
      visible.should contain("footnote[1]")
      visible.should contain("ref[1]")
    end

    it "collects definitions at the end under a Footnotes header" do
      result = Markd.to_term(source, options)
      visible = strip_ansi(result)
      # Body text first, then the header, then the definitions in order
      visible.should match(/More text.*Footnotes.*The first footnote\..*A named footnote\./m)
    end

    it "labels definitions with their numbers" do
      visible = strip_ansi(Markd.to_term(source, options))
      visible.should contain("[1] The first footnote.")
      visible.should contain("[2] A named footnote.")
    end
  end

  describe "in markdown output" do
    it "round-trips references with their labels" do
      result = Markd.to_md(source, options)
      result.should contain("footnote[^1]")
      result.should contain("one[^note]")
      result.should contain("ref[^1]")
    end

    it "round-trips definitions at column 0 with blank lines" do
      result = Markd.to_md(source, options)
      result.should contain("\n\n[^1]: The first footnote.")
      result.should contain("\n\n[^note]: A named footnote.")
    end

    it "is stable under repeated round-trips" do
      once = Markd.to_md(source, options)
      twice = Markd.to_md(once, options)
      twice.should eq(once)
    end
  end
end
