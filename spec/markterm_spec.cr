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
      Markd.to_term("> text\n> text2").should eq(
        "\n" + "  │ \e[37;3mtext\e[0m\n" + "  │ \e[37;3mtext2\e[0m\n"
      )
    end
    it "does links with just a URL" do
      Markd.to_term("<http://go.to>").should eq(
        "  \e[34;4m<http://go.to>\e[0m"
      )
    end
    it "does links with text" do
      Markd.to_term("[foo](http://go.to)").should eq(
        "  \e[34;4mfoo <http://go.to>\e[0m"
      )
    end
    it "removes text if it's just the URL" do
      Markd.to_term("[http://go.to](http://go.to)").should eq(
        "  \e[34;4m<http://go.to>\e[0m"
      )
    end
    it "uses OSC 8 for links when TERM is kitty" do
      ENV["TERM"] = "xterm-kitty"
      Markd.to_term("[foo](http://go.to)").should eq(
        "  \e[34;4m\e]8;;http://go.to\e\\foo\e]8;;\e\\\e[0m"
      )
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
