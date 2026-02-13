require "sixteen"

module Terminal
  struct Style
    property fore : Symbol | Colorize::ColorRGB | Nil
    property back : Symbol | Colorize::ColorRGB | Nil
    property bold : Bool?
    property bright : Bool?
    property dim : Bool?
    property blink : Bool?
    property reverse : Bool?
    property hidden : Bool?
    property italic : Bool?
    property blink_fast : Bool?
    property strikethrough : Bool?
    property underline : Bool?
    property double_underline : Bool?
    property overline : Bool?

    def initialize(@fore = nil, @back = nil, @bold = nil, @bright = nil, @dim = nil, @blink = nil, @reverse = nil, @hidden = nil, @italic = nil, @blink_fast = nil, @strikethrough = nil, @underline = nil, @double_underline = nil, @overline = nil)
    end

    macro merge_prop(prop)
      new.{{prop}} = other.{{prop}}.nil? ? self.{{prop}} : other.{{prop}}
    end

    def +(other : Style) : Style
      new = Style.new
      merge_prop fore
      merge_prop back
      merge_prop bold
      merge_prop bright
      merge_prop dim
      merge_prop blink
      merge_prop reverse
      merge_prop hidden
      merge_prop italic
      merge_prop blink_fast
      merge_prop strikethrough
      merge_prop underline
      merge_prop double_underline
      merge_prop overline
      new
    end
  end

  struct StyleStack
    @stack : Array(Style) = [] of Style

    def current : Style
      @stack.reduce(@stack[0]) { |acc, i| acc + i }
    end

    macro apply_prop(prop)
      input = input.{{prop}} if style.{{prop}}
    end

    def apply(input : String)
      style = current
      input = input.colorize
      style.fore.try { |col| input.fore(col) }
      style.back.try { |col| input.back(col) }
      apply_prop bold
      apply_prop bright
      apply_prop dim
      apply_prop blink
      apply_prop reverse
      apply_prop hidden
      apply_prop italic
      apply_prop blink_fast
      apply_prop strikethrough
      apply_prop underline
      apply_prop double_underline
      apply_prop overline

      input
    end

    # Returns the ANSI prefix for the current style
    def prefix : String
      apply("").to_s
    end

    def <<(style : Style)
      @stack << style
    end

    def pop : Style
      @stack.pop
    end

    def last : Style
      @stack.last
    end
  end

  def theme(name : String? = nil) : Hash(String, Style)
    t = {} of String => Style
    t["default"] = Style.new
    if name.nil?
      if terminal_light?
        t["block_quote"] = Style.new(fore: :black, italic: true)
        t["code"] = Terminal::Style.new(fore: :red, italic: true)
        t["emphasis"] = Terminal::Style.new(italic: true)
        t["heading"] = Terminal::Style.new(fore: :blue, underline: true, bold: true)
        t["link"] = Terminal::Style.new(fore: :blue, underline: true)
        t["strong"] = Terminal::Style.new(bold: true)
      else
        t["block_quote"] = Style.new(fore: :light_gray, italic: true)
        t["code"] = Terminal::Style.new(fore: :light_red, italic: true)
        t["emphasis"] = Terminal::Style.new(italic: true)
        t["heading"] = Terminal::Style.new(fore: :cyan, underline: true, bold: true)
        t["link"] = Terminal::Style.new(fore: :blue, underline: true)
        t["strong"] = Terminal::Style.new(bold: true)
      end
    else
      base16 = Sixteen.theme(name)
      t["block_quote"] = Style.new(fore: base16["05"].colorize, italic: true)
      t["code"] = Terminal::Style.new(fore: base16["0B"].colorize, italic: true)
      t["emphasis"] = Terminal::Style.new(italic: true)
      t["heading"] = Terminal::Style.new(fore: base16["0D"].colorize, underline: true, bold: true)
      t["link"] = Terminal::Style.new(fore: base16["09"].colorize, underline: true)
      t["strong"] = Terminal::Style.new(bold: true)
    end
    t
  end
end
