require "./spec_helper"

basic_style = Terminal::Style.new
basic_style.fore = :white
basic_style.back = :black
basic_style.underline = false
basic_style.bold = false
basic_style.italic = false

fore_only = Terminal::Style.new
fore_only.fore = :red

# These variables affect test outcomes
ENV["TERM"] = "xterm"
ENV["TERM_PROGRAM"] = "xterm"

describe "Markterm" do
  describe "TermRenderer" do
    it "works" do
      Markd.to_term("text").should eq("  text")
    end
    it "does block quotes" do
      result = Markd.to_term("> text\n> text2")
      result.should contain("text")
      result.should contain("text2")
      result.should contain("│")
    end
    it "does links with just a URL" do
      result = Markd.to_term("<http://go.to>")
      result.should contain("<http://go.to>")
    end
    it "does links with text, with a condensed dimmed destination" do
      result = Markd.to_term("[foo](http://go.to/very/long/path/that/goes/on/and/on/forever)")
      plain = result.gsub(/\e\[[0-9;]*m/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      plain.should contain("foo")
      # scheme dropped, path elided: readable without breaking flow
      plain.should contain("(go.to/very/long/path/that/goes/o…/forever)")
      plain.should_not contain("http://")
    end
    it "removes text if it's just the URL" do
      result = Markd.to_term("[http://go.to](http://go.to)")
      plain = result.gsub(/\e\[[0-9;]*m/, "")
      plain.should contain("http://go.to")
      plain.should_not contain("(go.to)")
      plain.scan(/go\.to/).size.should eq(1)
    end
    it "does not repeat relative destinations" do
      result = Markd.to_term("[BUILDING.md](BUILDING.md)")
      plain = result.gsub(/\e\[[0-9;]*m/, "")
      plain.should contain("BUILDING.md")
      plain.should_not contain("(BUILDING.md)")
    end
    it "uses OSC 8 for links when TERM is kitty" do
      ENV["TERM"] = "xterm-kitty"
      result = Markd.to_term("[foo](http://go.to)", force_links: true)
      result.should contain("\e]8;;http://go.to\e\\")
      ENV["TERM"] = "xterm"
    end
  end
  describe "Style" do
    it "adds" do
      new_s = basic_style + fore_only
      new_s.fore.should eq(:red)
      new_s.back.should eq(:black)
    end
  end
  describe "StyleStack" do
    it "works" do
      stack = Terminal::StyleStack.new
      stack << basic_style
      stack.last.fore.should eq(:white)
      stack.last.back.should eq(:black)
      stack.last.underline.should be_false
    end

    it "applies styles" do
      stack = Terminal::StyleStack.new
      stack << basic_style
      stack.apply("test").to_s.should eq(
        "test".colorize.fore(:white).back(:black).to_s)
    end

    it "merges partial styles" do
      stack = Terminal::StyleStack.new
      stack << basic_style
      stack << fore_only
      stack.current.fore.should eq(:red)
      stack.current.back.should eq(:black)
    end
  end
end

describe "GFM features" do
  it "renders strikethrough without crashing" do
    options = Markd::Options.new
    options.gfm = true
    result = Markd.to_term("hello ~~gone~~ world", options)
    result.should contain("hello")
    result.should contain("gone")
    result.should contain("world")
    # SGR 9 is strikethrough
    result.should match(/\e\[9m/)
  end

  it "defines a strikethrough style in the default theme" do
    Terminal.theme["strikethrough"].strikethrough.should be_true
  end
end

describe "Table rendering" do
  it "renders basic table in TermRenderer" do
    markdown = "| Name | Age |\n|------|-----|\n| Alice | 30 |"
    options = Markd::Options.new
    options.gfm = true
    result = Markd.to_term(markdown, options)
    result.should contain("Alice")
    result.should contain("Name")
  end

  it "renders markdown table in MarkRenderer" do
    markdown = "| Name | Age |\n|------|-----|\n| Alice | 30 |"
    options = Markd::Options.new
    options.gfm = true
    result = Markd.to_md(markdown, options)
    result.should contain("| Name | Age |")
    result.should contain("| --- | --- |")
  end

  it "renders images with empty alt text" do
    result = Markd.to_md("![](http://example.com/cat.png)")
    result.should contain("![](http://example.com/cat.png)")
  end

  it "round-trips strikethrough" do
    options = Markd::Options.new
    options.gfm = true
    result = Markd.to_md("hello ~~gone~~ world", options)
    result.should eq("hello ~~gone~~ world")
  end
end

describe "Word wrap" do
  it "does not corrupt paragraphs with $$ inside code spans" do
    source = "Markdown math (`$E = mc^2$` inline, `$$…$$` display) is rendered as styled Unicode."
    result = Markd.to_term(source)
    result.should contain("display) is rendered as styled Unicode")
    result.should contain("$$…$$")
  end

  it "wraps paragraphs to max_width" do
    long_text = "This is a long paragraph that should wrap to fit within the specified width."
    result = Markd.to_term(long_text, max_width: 20)
    lines = result.strip.split("\n")
    # Each line should be at most 20 visible characters (excluding ANSI codes)
    lines.each do |line|
      # Strip ANSI codes for length check
      visible = line.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      visible.size.should be <= 20
    end
  end

  it "wraps CJK text respecting display width, not codepoint count" do
    # 30 words of two han glyphs each: 4 columns per word. With the
    # 2-column block indent, 3 words (14 columns) fit on a 20-column
    # line and a 4th would need 19 > 18 available — counting
    # codepoints would wrongly fit 6 words.
    result = Markd.to_term(("中文 " * 30).strip, max_width: 20)
    result.strip.split("\n").each do |line|
      visible = line.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      Terminal.display_width(visible).should be <= 20, "line too wide: #{visible.inspect}"
    end
    # 30 words at 3 per line must take 10 lines, not fewer
    result.strip.split("\n").size.should eq(10)
  end

  it "wraps headings to max_width" do
    heading = "# This is a very long heading that needs wrapping"
    result = Markd.to_term(heading, max_width: 25)
    lines = result.strip.split("\n")
    lines.each do |line|
      visible = line.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      visible.size.should be <= 25
    end
  end

  it "does not wrap when max_width is nil" do
    long_text = "This is a long paragraph that should not wrap when max_width is nil."
    result = Markd.to_term(long_text, max_width: nil)
    # Should be a single line (plus indent)
    result.strip.split("\n").size.should eq(1)
  end

  it "soft-wraps over-wide code lines with indented continuations" do
    code = "```\nthis_is_a_very_long_line_of_code_that_should_never_overflow_the_terminal_width\n```"
    result = Markd.to_term(code, max_width: 30)
    plain = result.gsub(/\e\[[0-9;]*[mGKH]/, "")
    # nothing is lost: whitespace (the wrap) is the only addition
    plain.gsub(/\s/, "").should contain("this_is_a_very_long_line_of_code_that_should_never_overflow_the_terminal_width")
    lines = plain.strip.split("\n").reject(&.strip.empty?)
    lines.each do |line|
      line.size.should be <= 30, "code line overflowed: #{line.inspect}"
    end
    # continuation lines indent past the code block's content column
    lines.select(&.starts_with?("      ")).should_not be_empty
  end

  it "handles long words by letting them overflow" do
    text = "short supercalifragilisticexpialidocious short"
    result = Markd.to_term(text, max_width: 30)
    # The long word should appear intact (not split)
    result.should contain("supercalifragilisticexpialidocious")
  end

  it "wraps list items" do
    list = "- This is a very long list item that should wrap properly when width is limited"
    result = Markd.to_term(list, max_width: 25)
    lines = result.strip.split("\n")
    lines.each do |line|
      visible = line.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      visible.size.should be <= 25
    end
  end

  it "preserves ANSI styling in wrapped text" do
    styled = "**bold text here that is long enough to wrap**"
    result = Markd.to_term(styled, max_width: 20)
    # Should still contain ANSI codes for bold
    result.should match(/\e\[1m/)
  end

  it "wraps block quotes with indentation" do
    quote = "> This is a long block quote that should wrap properly with the indent prefix."
    result = Markd.to_term(quote, max_width: 25)
    lines = result.strip.split("\n")
    lines.each do |line|
      visible = line.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
      visible.size.should be <= 25
    end
  end

  it "preserves soft breaks inside wrapped paragraphs" do
    result = Markd.to_term("line1\nline2 here", max_width: 20)
    result.strip.should eq("line1\n  line2 here")
  end

  it "keeps soft break segments in order when wrapping" do
    text = "alpha beta gamma delta\nepsilon zeta eta theta iota kappa"
    result = Markd.to_term(text, max_width: 20)
    visible = result.gsub(/\e\[[0-9;]*[mGKH]/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
    visible.should match(/alpha.*delta/m)
    visible.should match(/delta\s+epsilon/m)
    visible.should_not contain("deltaepsilon")
  end
end

describe "Image rendering" do
  it "falls back to an image placeholder when the image cannot be shown" do
    # A nonexistent file makes timg fail on machines that have it,
    # and is equivalent to not having timg at all on machines that don't
    result = Markd.to_term("![dot](/nonexistent/path/image.png)")
    result.should contain("[image: dot]")
    result.should_not contain("/nonexistent/path/image.png")
  end

  it "suppresses alt-less images inside links entirely" do
    # Badges: an empty image inside a link would only repeat what the
    # link itself says
    result = Markd.to_term("[![CI](https://example.com/badge.svg)](https://example.com/ci)")
    result.should contain("CI")
    result.should_not contain("badge.svg")
  end
end

describe "Terminal width detection" do
  it "returns an integer width or nil" do
    # The result depends on the environment (TTY, env vars, etc.)
    result = Terminal.terminal_width
    result.nil? || result.should be_a(Int32)
  end
end

describe "Hyphenation" do
  it "breaks long words at syllable boundaries when enabled" do
    result = Markd.to_term(("internationalization " * 6).strip, max_width: 20, hyphenate: true)
    plain = result.gsub(/\e\[[0-9;]*m/, "")
    lines = plain.strip.split("\n")
    lines.each do |line|
      line.size.should be <= 20, "line overflowed: #{line.inspect}"
    end
    lines.select(&.ends_with?("-")).should_not be_empty
    # nothing lost: un-joining the break hyphens restores every word
    plain.gsub("-\n", "").gsub(/\s/, "").scan(/internationalization/).size.should eq(6)
  end

  it "leaves words whole when not enabled" do
    result = Markd.to_term("internationalization", max_width: 20)
    plain = result.gsub(/\e\[[0-9;]*m/, "")
    plain.should contain("internationalization")
    plain.strip.split("\n").each do |line|
      line.should_not end_with("-")
    end
  end

  it "does not hyphenate code spans" do
    result = Markd.to_term("before `internationalization` after", max_width: 20, hyphenate: true)
    plain = result.gsub(/\e\[[0-9;]*m/, "")
    plain.should contain("internationalization")
    plain.strip.split("\n").each do |line|
      line.should_not end_with("-")
    end
  end

  it "does not hyphenate link text" do
    result = Markd.to_term("[internationalization](https://example.com/path)", max_width: 20, hyphenate: true)
    plain = result.gsub(/\e\[[0-9;]*m/, "").gsub(/\e\]8;;[^\e]*\e\\/, "")
    plain.should contain("internationalization")
    plain.strip.split("\n").each do |line|
      line.should_not end_with("-")
    end
  end

  it "hyphenates spanish words with language es" do
    result = Markd.to_term(("internacionalización " * 6).strip, max_width: 20, hyphenate: true, language: "es")
    plain = result.gsub(/\e\[[0-9;]*m/, "")
    plain.strip.split("\n").select(&.ends_with?("-")).should_not be_empty
    plain.gsub("-\n", "").gsub(/\s/, "").scan(/internacionalización/).size.should eq(6)
  end

  it "rejects an unknown hyphenation language" do
    expect_raises(ArgumentError) do
      Markd.to_term("text", max_width: 20, hyphenate: true, language: "tlh")
    end
  end
end
