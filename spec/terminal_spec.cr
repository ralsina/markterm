require "./spec_helper"

describe "Terminal" do
  describe "parse_color" do
    it "parses a full terminal color reply" do
      # The reply to an OSC 11 query, including prefix and terminator
      Terminal.parse_color("\e]11;rgb:1c1c/1c1c/1c1c\e\\").should eq([0x1c, 0x1c, 0x1c])
    end

    it "parses the red, green and blue channels in the right order" do
      Terminal.parse_color("rgb:ff00/0100/0200").should eq([0xff, 0x01, 0x02])
    end

    it "parses uppercase hex" do
      Terminal.parse_color("rgb:ABCD/EF01/2345").should eq([0xab, 0xef, 0x23])
    end

    it "parses short two-digit components" do
      Terminal.parse_color("rgb:ff/00/7f").should eq([0xff, 0x00, 0x7f])
    end

    it "returns nil for unparseable replies" do
      Terminal.parse_color("garbage").should be_nil
      Terminal.parse_color("").should be_nil
    end
  end

  describe "supports_links?" do
    it "does not claim OSC 8 support when output is not a tty" do
      # Specs run with piped output
      Terminal.supports_links?.should be_false
    end
  end

  describe "supports_images?" do
    it "returns a bool" do
      Terminal.supports_images?.should be_a(Bool)
    end
  end

  describe "terminal_light?" do
    it "honors a dark COLORFGBG without querying the terminal" do
      old_value = ENV["COLORFGBG"]?
      ENV["COLORFGBG"] = "15;0"
      Terminal.terminal_light?.should be_false
      if old_value
        ENV["COLORFGBG"] = old_value
      else
        ENV.delete("COLORFGBG")
      end
    end
  end

  describe "theme" do
    it "has all the styles the renderer looks up" do
      # Both the default and the named-theme branch must define
      # every key TermRenderer reads, or rendering raises KeyError
      required = ["default", "block_quote", "code", "emphasis", "heading",
                  "link", "strong", "strikethrough"]
      default_theme = Terminal.theme
      named_theme = Terminal.theme("3024")
      required.each do |key|
        default_theme[key]?.should_not be_nil, "default theme is missing '#{key}'"
        named_theme[key]?.should_not be_nil, "named theme is missing '#{key}'"
      end
    end

    it "raises a clear error for an unknown theme" do
      expect_raises(Exception, "Theme not found") do
        Terminal.theme("no-such-theme-xyz")
      end
    end

    it "uses the dark palette by default in non-tty environments" do
      theme = Terminal.theme
      theme["heading"].fore.should eq(:cyan)
      theme["code"].fore.should eq(:light_red)
    end

    it "builds named themes from base16 palettes" do
      theme = Terminal.theme("3024")
      theme["heading"].fore.should be_a(Colorize::ColorRGB)
    end
  end
end
