require "./spec_helper"

basic_style = Markd::Style.new
basic_style.fore = :white
basic_style.back = :black
basic_style.underline = false
basic_style.bold = false
basic_style.italic = false

fore_only = Markd::Style.new
fore_only.fore = :red

describe "Markterm" do
  describe "Style" do
    it "adds" do
      new_s = basic_style + fore_only
      new_s.fore.should eq(:red)
      new_s.back.should eq(:black)
    end
  end
  describe "StyleStack" do
    it "works" do
      stack = Markd::StyleStack.new
      stack << basic_style
      stack.last.fore.should eq(:white)
      stack.last.back.should eq(:black)
      stack.last.underline.should eq(false)
    end

    it "applies styles" do
      stack = Markd::StyleStack.new
      stack << basic_style
      stack.apply("test").to_s.should eq(
        "test".colorize.fore(:white).back(:black).to_s)
    end

    it "merges partial styles" do
      stack = Markd::StyleStack.new
      stack << basic_style
      stack << fore_only
      stack.current.fore.should eq(:red)
      stack.current.back.should eq(:black)
    end
  end
end
