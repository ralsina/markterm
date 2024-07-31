module Terminal
  struct Style
    property fore : Symbol?
    property back : Symbol?
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
      input = input.fore(style.fore.as(Symbol)) if style.fore
      input = input.back(style.back.as(Symbol)) if style.back
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
end
