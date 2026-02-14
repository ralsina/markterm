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
    it "does links with text" do
      result = Markd.to_term("[foo](http://go.to)")
      result.should contain("foo")
      result.should contain("<http://go.to>")
    end
    it "removes text if it's just the URL" do
      result = Markd.to_term("[http://go.to](http://go.to)")
      result.should contain("<http://go.to>")
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
      stack.last.underline.should eq(false)
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
end

describe "Word wrap" do
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

  it "does not wrap code blocks" do
    code = "```\nthis_is_a_very_long_line_of_code_that_should_not_be_wrapped_at_all\n```"
    result = Markd.to_term(code, max_width: 20)
    result.should contain("this_is_a_very_long_line_of_code_that_should_not_be_wrapped_at_all")
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
end

describe "Terminal width detection" do
  it "returns an integer width or nil" do
    # The result depends on the environment (TTY, env vars, etc.)
    result = Terminal.terminal_width
    result.nil? || result.should be_a(Int32)
  end
end
