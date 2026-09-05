require "./spec_helper"

describe "GFM rendering (to_term)" do
  options = Markd::Options.new
  options.gfm = true

  it "renders headings with their level even without max_width" do
    result = Markd.to_term("# Top\n\n## Sub", options)
    visible = result.gsub(/\e\[[0-9;]*[mGKH]/, "")
    visible.should contain("# Top")
    visible.should contain("## Sub")
  end

  it "renders task list checkboxes" do
    result = Markd.to_term("- [x] done thing\n- [ ] open thing", options)
    result.should contain("[x]")
    result.should contain("[ ]")
    result.should contain("done thing")
    result.should contain("open thing")
    # They must not be renumbered as an ordered list
    result.should_not match(/\d\. /)
  end

  it "renders bullet lists with bullet markers" do
    result = Markd.to_term("- one\n- two", options)
    result.should contain("•")
    result.should_not match(/\d\. /)
  end

  it "renders ordered lists with numbers" do
    result = Markd.to_term("1. one\n2. two", options)
    result.should contain("1.")
    result.should contain("2.")
  end

  it "renders the alert title in a quote gutter" do
    result = Markd.to_term("> [!NOTE]\n> note body", options)
    result.should contain("NOTE")
    result.should contain("│")
    result.should contain("note body")
  end

  it "renders tables with all rows" do
    markdown = "| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |"
    result = Markd.to_term(markdown, options)
    result.should contain("Name")
    result.should contain("Alice")
    result.should contain("Bob")
    # line-drawing table borders (Tablo Modern preset)
    result.should contain("│")
    result.should contain("┌")
  end

  it "wraps wide tables to max_width" do
    markdown = "| Column One | Column Two | Column Three |\n|---|---|---|\n| some long content here | middle sized | tiny |"
    result = Markd.to_term(markdown, options, max_width: 40)
    result.split("\n").each do |line|
      visible = line.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      visible.size.should be <= 40
    end
    result.should contain("middle")
    result.should contain("sized")
  end

  it "restores styled cells without leaking placeholder characters" do
    was_enabled = Colorize.enabled?
    Colorize.enabled = true
    markdown = "| Col A | Col B |\n|---|---|\n| long text content that needs space | `code` and **bold** |"
    result = Markd.to_term(markdown, options, max_width: 30)
    # PUA characters are internal placeholders and must never leak,
    # and the styled text must still be present (tablo may wrap a
    # styled run mid-word when the table is squeezed)
    result.should_not contain('\uE000'.to_s)
    result.should contain("code")
    result.should contain("and")
    result.should contain("old")
    Colorize.enabled = was_enabled
  end

  it "highlights fenced code blocks" do
    code = "```crystal\nputs \"hello\"\n```"
    result = Markd.to_term(code, options)
    result.should contain("puts")
    # Tartrazine's ANSI formatter emits escape sequences
    result.should match(/\e\[/)
  end

  it "falls back to plaintext for unknown code languages" do
    code = "```not-a-real-language\nplain text here\n```"
    result = Markd.to_term(code, options)
    result.should contain("plain text here")
  end

  it "renders html blocks" do
    result = Markd.to_term("<div>\n  some html\n</div>", options)
    result.should contain("some html")
  end

  it "renders nested lists" do
    markdown = "- outer\n  - inner\n- outer again"
    result = Markd.to_term(markdown, options)
    result.should contain("outer")
    result.should contain("inner")
  end
end
