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
  class MarkRenderer < Renderer
    @indent = [] of String
    @current_item = [] of Int32

    def initialize(@options = Options.new)
      @output_io = String::Builder.new
      @last_output = "\n"
    end

    def print(s)
      s = s.to_s.gsub("\n", "\n" + @indent.join)
      @output_io << s
    end

    def block_quote(node : Node, entering : Bool)
      if entering
        print "\n"
        @indent << "│ "
      else
        @indent.pop
        print "\n"
      end
    end

    def code(node : Node, entering : Bool)
      if entering
        print "`#{node.text}`"
      end
    end

    def code_block(node : Node, entering : Bool)
      languages = node.fence_language ? node.fence_language.split : nil
      if languages
        print "\n\n```#{languages[0]}\n"
      else
        print "\n\n```\n"
      end
      print node.text
      print "```\n\n"
    end

    def emphasis(node : Node, entering : Bool)
      if entering
        print "*"
      else
        print "*"
      end
    end

    def heading(node : Node, entering : Bool)
      if entering
        level = node.data["level"].as(Int32)
        print "\n\n#{"#" * level} "
      else
        print "\n"
      end
    end

    def html_block(node : Node, entering : Bool)
      print "\n\n"
      print node.text
    end

    def html_inline(node : Node, entering : Bool)
      print node.text
    end

    def image(node : Node, entering : Bool)
      if entering
        print "![#{node.first_child.text}](#{node.data["destination"].as(String)})"
      end
    end

    def item(node : Node, entering : Bool)
      if entering
        if node.parent?.try &.data["type"] == "bullet"
          marker = "* "
        else
          @current_item[-1] += 1
          marker = "#{@current_item[-1]}. "
        end
        print "\n"
        print "#{marker}"
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
        print "\n"
      else
        print "\n"
      end
    end

    def strong(node : Node, entering : Bool)
      print "**"
    end

    def text(node : Node, entering : Bool)
      if node.parent?.try &.type == Node::Type::Link
        # The parent node is a link, so we need to handle
        # specially.
        dest = node.parent.data["destination"].as(String)
        if dest == node.text
          # This is a bare URL, just print it.
          print "<#{dest}>"
        else
          # This is a link with text. In some terminals, we can get fancy
          # and show a HTML-style hyperlink.
          print "[#{node.text}](#{dest})"
        end
        # Image nodes already print their children's text
      elsif node.parent?.try &.type != Node::Type::Image
        print node.text
      end
    end

    def thematic_break(node : Node, entering : Bool)
      if entering
        print "\n\n"
        print "-" * 40
        print "\n"
      end
    end

    def strikethrough(node : Node, entering : Bool)
      if entering
        print "~~"
        print node.text
        print "~~"
      end
    end

    def render(document : Node) : String
      super.split("\n").map(&.rstrip).join("\n")
    end
  end

  def self.to_md(source : String, options = Options.new) : String
    return "" if source.empty?
    document = Parser.parse(source, options)
    renderer = MarkRenderer.new(options)
    renderer.render(document).strip("\n")
  end
end
