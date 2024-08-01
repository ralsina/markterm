require "./terminal"
require "./styles"
require "colorize"
require "markd"

macro def_method(name)
  def {{name}}(node : Node, entering : Bool)
    if entering
      print "{{name}}\n"
    end
  end
end

module Markd
  class TermRenderer < Renderer
    @style : Terminal::StyleStack = Terminal::StyleStack.new
    @theme = Terminal.theme
    @indent = ["  "]
    @current_item = [] of Int32

    def initialize(@options = Options.new)
      @output_io = String::Builder.new
      @last_output = "\n"
      @style << @theme["default"]
      Colorize.on_tty_only!
    end

    def print(s)
      s = s.to_s.gsub("\n", "\n" + @indent.join)
      @output_io << s
    end

    def block_quote(node : Node, entering : Bool)
      if entering
        print "\n"
        @indent << "│ "
        @style << @theme["block_quote"]
      else
        @indent.pop
        @style.pop
        print "\n"
      end
    end

    def code(node : Node, entering : Bool)
      if entering
        @style << @theme["code"]
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
        code = Terminal.highlight(node.text, languages[0])
        print code
      end
      @indent.pop
    end

    def emphasis(node : Node, entering : Bool)
      if entering
        @style << @theme["emphasis"]
      else
        @style.pop
      end
    end

    def heading(node : Node, entering : Bool)
      if entering
        @style << @theme["heading"]
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

    def image(node : Node, entering : Bool)
      title = node.data["title"].as(String) + " "
      if entering
        if Terminal.supports_images?
          Colorize.reset
          print "\n\n" + Terminal.show_image(node.data["destination"].as(String)) + "\n"
        else
          print @style.apply "\n\n[#{title}#{node.data["destination"].as(String)}]\n"
        end
      else
        print "\n"
      end
    end

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
        @indent << "   "
      else
        @indent.pop
      end
    end

    def line_break(node : Node, entering : Bool)
      print "\n"
    end

    # The `link` method sets the style but doesn't
    # print the link, the children nodes do that.
    #
    # They will get the destination by looking up
    # their parent.
    def link(node : Node, entering : Bool)
      if entering
        @style << @theme["link"]
      else
        # destination = node.data["destination"].as(String)
        # print @style.apply "<#{destination}>"
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
      # When in a paragraph, soft breaks are just spaces.
      if node.parent.try &.type == Node::Type::Paragraph
        print @style.apply " "
      else
        print "\n"
      end
    end

    def strong(node : Node, entering : Bool)
      if entering
        @style << @theme["strong"]
      else
        @style.pop
      end
    end

    def text(node : Node, entering : Bool)
      if node.parent?.try &.type == Node::Type::Link
        # The parent node is a link, so we need to handle
        # specially.
        dest = node.parent.data["destination"].as(String)
        if dest == node.text
          # This is a bare URL, just print it.
          print @style.apply "<#{dest}>"
        else
          # This is a link with text. In some terminals, we can get fancy
          # and show a HTML-style hyperlink.
          if Terminal.supports_links?
            print @style.apply "\e]8;;#{dest}\e\\#{node.text}\e]8;;\e\\"
          else
            print @style.apply "#{node.text} <#{dest}>"
          end
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
