require "markd"
require "colorize"

macro def_method(name)
  def {{name}}(node : Node, entering : Bool)
    if entering
      print "{{name}}\n"
    end
  end
end

module Markd
  struct Style
    property fore : Symbol? = nil
    property back : Symbol? = nil
    property bold : Bool? = nil
    property bright : Bool? = nil
    property dim : Bool? = nil
    property blink : Bool? = nil
    property reverse : Bool? = nil
    property hidden : Bool? = nil
    property italic : Bool? = nil
    property blink_fast : Bool? = nil
    property strikethrough : Bool? = nil
    property underline : Bool? = nil
    property double_underline : Bool? = nil
    property overline : Bool? = nil

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

  class TermRenderer < Renderer
    @style : StyleStack = StyleStack.new
    @indent = ["  "]
    @current_item = [] of Int32

    def initialize(@options = Options.new)
      @output_io = String::Builder.new
      @last_output = "\n"
      s = Style.new
      s.fore = nil
      s.back = nil
      s.underline = false
      s.bold = false
      s.italic = false
      @style << s
    end

    def print(s)
      s = s.to_s.gsub("\n", "\n" + @indent.join)
      @output_io << s
    end

    def block_quote(node : Node, entering : Bool)
      if entering
        print "\n"
        @indent << "│ "
        s = Style.new
        s.fore = :light_gray
        s.italic = true
        @style << s
      else
        @indent.pop
        @style.pop
        print "\n"
      end
    end

    def code(node : Node, entering : Bool)
      if entering
        s = Style.new
        s.fore = :red
        s.back = :dark_gray
        s.italic = true
        @style << s
        print @style.apply(node.text)
        @style.pop
      end
    end

    def code_block(node : Node, entering : Bool)
      languages = node.fence_language ? node.fence_language.split : nil
      @indent << "  "
      print "\n\n"
      if languages.nil? || languages.empty?
        print node.text
      else
        code = highlight(node.text, languages[0])
        print code
      end
      @indent.pop
    end

    def emphasis(node : Node, entering : Bool)
      if entering
        s = Style.new
        s.italic = true
        @style << s
      else
        @style.pop
      end
    end

    def heading(node : Node, entering : Bool)
      if entering
        s = Style.new
        s.underline = true
        s.bold = true
        s.double_underline = true
        s.fore = :cyan
        @style << s
        level = node.data["level"].as(Int32)
        print "\n\n"
        print @style.apply("#{"#" * level} ")
      else
        print "\n"
        @style.pop
      end
    end

    def_method html_block
    def_method html_inline
    def_method image

    def item(node : Node, entering : Bool)
      if entering
        if node.parent?.try &.data["type"] == "bullet"
          marker = "• "
        else
          @current_item[-1] += 1
          marker = "#{@current_item[-1]}. "
        end
        print "\n"
        print @style.apply("#{marker} ")
        @indent << "  "
      else
        @indent.pop
      end
    end

    def line_break(node : Node, entering : Bool)
      print "\n"
    end

    def link(node : Node, entering : Bool)
      if entering
        s = Style.new
        s.underline = true
        s.fore = :blue
        @style << s
      else
        destination = node.data["destination"].as(String)
        print @style.apply "<#{destination}>"
        @style.pop
      end
    end

    def list(node : Node, entering : Bool)
      if entering
        @current_item << node.data["start"].as(Int32) - 1
      else
        @current_item.pop
      end
    end

    def paragraph(node : Node, entering : Bool)
      if entering && node.parent?.try(&.type) != Node::Type::Item
        print "\n"
      end
    end

    def soft_break(node : Node, entering : Bool)
      print "\n"
    end

    def strong(node : Node, entering : Bool)
      if entering
        s = Style.new
        s.bold = true
        @style << s
      else
        @style.pop
      end
    end

    def text(node : Node, entering : Bool)
      if node.parent?.try &.type == Node::Type::Link
        if node.parent.data["destination"].as(String) == node.text
          # Do nothing
        else
          print @style.apply "#{node.text} "
        end
      else
        print @style.apply node.text
      end
    end

    def thematic_break(node : Node, entering : Bool)
      if entering
        print "\n\n"
        print @style.apply("-" * 40)
        print "\n"
      end
    end

    def highlight(source : String, language : String) : String
      result = ""
      Process.run(
        "chroma",
        Process.parse_arguments_posix("-f terminal -l '#{language}' -s autumn"),
        input: IO::Memory.new(source),
        output: Process::Redirect::Pipe) do |process|
        result += process.output.gets_to_end
      end
      result
    end

    def indent(s, n)
      s.split("\n").map { |line| " " * n + line }.join("\n")
    end

    def render(document : Node) : String
      super.split("\n").map(&.rstrip).join("\n")
    end
  end

  def self.to_term(source : String, options = Options.new) : String
    return "" if source.empty?
    document = Parser.parse(source, options)
    renderer = TermRenderer.new(options)
    renderer.render(document)
  end
end
