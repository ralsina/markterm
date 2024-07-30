require "markd"
require "colorize"

macro def_method(name)
  def {{name}}(node : Node, entering : Bool)
    if entering
      @output_io << "{{name}}\n"
    end
  end
end

module Markd
  struct Style
    property bold : Bool? = nil
    property italic : Bool? = nil
    property underline : Bool? = nil
    property fore : Symbol? = nil
    property back : Symbol? = nil

    def +(other : Style) : Style
      new = Style.new
      new.bold = other.bold.nil? ? self.bold : other.bold
      new.underline = other.underline.nil? ? self.underline : other.underline
      new.italic = other.italic.nil? ? self.italic : other.italic
      new.fore = other.fore.nil? ? self.fore : other.fore
      new.back = other.back.nil? ? self.back : other.back
      new
    end
  end

  struct StyleStack
    @stack : Array(Style) = [] of Style

    def current : Style
      @stack.reduce(@stack[0]) { |acc, i| acc + i }
    end

    def apply(input : String)
      style = current
      input = input.colorize.fore(style.fore.as(Symbol)) \
        .back(style.back.as(Symbol))
      input = input.bold if style.bold
      input = input.underline if style.underline
      input = input.italic if style.italic
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

  class TermRenderer < Renderer
    @style : StyleStack = StyleStack.new

    def initialize(@options = Options.new)
      @output_io = String::Builder.new
      @last_output = "\n"
      s = Style.new
      s.fore = :white
      s.back = :black
      s.underline = false
      s.bold = false
      s.italic = false
      @style << s
    end

    def_method block_quote
    def_method code
    def_method code_block
    def_method emphasis
    def_method heading
    def_method html_block
    def_method html_inline
    def_method image
    def_method item
    def_method line_break

    def link(node : Node, entering : Bool)
      if entering
        s = Style.new
        s.underline = true
        s.fore = :blue
        @style << s
      else
        destination = node.data["destination"].as(String)
        @output_io << @style.apply " <#{destination}>"
        @style.pop
      end
    end

    def_method list
    def_method paragraph
    def_method soft_break
    def_method strong

    def text(node : Node, entering : Bool)
      @output_io << @style.apply node.text
    end

    def_method thematic_break
  end

  def self.to_term(source : String, options = Options.new) : String
    return "" if source.empty?
    document = Parser.parse(source, options)
    renderer = TermRenderer.new(options)
    renderer.render(document)
  end
end
