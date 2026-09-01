require "./spec_helper"

# MarkRenderer (markdown -> markdown) should round-trip documents:
# parsing its own output must give the same markdown back
describe "MarkRenderer round-trips" do
  options = Markd::Options.new
  options.gfm = true

  it "round-trips headings" do
    Markd.to_md("# Heading 1\n\n## Heading 2", options).should contain("# Heading 1")
  end

  it "round-trips emphasis and strong" do
    result = Markd.to_md("some *emphasis* and **strength**", options)
    result.should contain("*emphasis*")
    result.should contain("**strength**")
  end

  it "round-trips inline code" do
    Markd.to_md("a `code` b", options).should eq("a `code` b")
  end

  it "round-trips fenced code blocks with language" do
    source = "```crystal\nputs 1\n```"
    Markd.to_md(source, options).should eq("```crystal\nputs 1\n```")
  end

  it "round-trips bullet lists" do
    result = Markd.to_md("- one\n- two", options)
    result.should contain("one")
    result.should contain("two")
    result.should_not match(/\d\. /)
  end

  it "round-trips ordered lists with numbering" do
    Markd.to_md("1. one\n2. two", options).should eq("1. one\n2. two")
  end

  it "round-trips checked and unchecked task lists" do
    result = Markd.to_md("- [x] done thing\n- [ ] open thing", options)
    result.should contain("- [x] done thing")
    result.should contain("- [ ] open thing")
  end

  it "round-trips block quotes" do
    Markd.to_md("> quoted text", options).should eq("> quoted text")
  end

  it "round-trips links" do
    Markd.to_md("[text](http://x.com)", options).should eq("[text](http://x.com)")
  end

  it "round-trips soft breaks as line breaks" do
    Markd.to_md("line1\nline2", options).should eq("line1\nline2")
  end

  it "round-trips thematic breaks" do
    result = Markd.to_md("before\n\n---\n\nafter", options)
    result.should contain("before")
    result.should contain("after")
    # 40 dashes are still a valid thematic break
    result.should match(/^-{10,}$/m)
  end

  it "keeps GFM alerts as alerts" do
    result = Markd.to_md("> [!NOTE]\n> note body", options)
    result.should contain("[!NOTE]")
    result.should contain("> note body")
  end

  it "includes custom alert titles" do
    result = Markd.to_md("> [!TIP] Custom advice\n> the advice", options)
    result.should contain("[!TIP] Custom advice")
    result.should contain("> the advice")
  end
end
