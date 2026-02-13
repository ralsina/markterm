require "./terminal"
require "./styles"
require "colorize"
require "markd"
require "tablo"

macro def_method(name)
  def {{name}}(node : Node, entering : Bool) : Nil
    if entering
      print "{{name}}\n"
    end
  end
end

module Markd
  class TermRenderer < Renderer
    @style : Terminal::StyleStack = Terminal::StyleStack.new
    @theme = Terminal.theme
    @code_theme : String?
    @indent = ["  "]
    @current_item = [] of Int32
    @force_links = false
    @table_data : Array(Array(String)) = [] of Array(String)
    @table_alignments : Array(String) = [] of String
    @current_row : Array(String) = [] of String

    def initialize(@options = Options.new, theme : String? = nil, code_theme : String? = nil, @force_links : Bool = false)
      @output_io = String::Builder.new
      @last_output = "\n"
      @theme = Terminal.theme(theme)
      @code_theme = code_theme
      @style << @theme["default"]
    end

    def print(s)
      s = s.to_s.gsub("\n", "\n" + @indent.join)
      @output_io << s
    end

    def block_quote(node : Node, entering : Bool) : Nil
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

    def code(node : Node, entering : Bool) : Nil
      if entering
        @style << @theme["code"]
        print @style.apply(node.text)
        @style.pop
      end
    end

    def code_block(node : Node, entering : Bool, formatter : T?) : Nil forall T
      languages = node.fence_language ? node.fence_language.split : nil
      @indent << "  "
      print "\n\n"
      if languages.nil? || languages.empty?
        print node.text
      else
        code = Terminal.highlight(node.text, languages[0], @code_theme)
        print code
      end
      @indent.pop
    end

    def emphasis(node : Node, entering : Bool) : Nil
      if entering
        @style << @theme["emphasis"]
      else
        @style.pop
      end
    end

    def heading(node : Node, entering : Bool) : Nil
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

    def html_block(node : Node, entering : Bool) : Nil
      print "\n\n"
      print Terminal.highlight(node.text, "html", @code_theme)
    end

    def html_inline(node : Node, entering : Bool) : Nil
      print Terminal.highlight(node.text, "html", @code_theme)
    end

    def image(node : Node, entering : Bool) : Nil
      title = node.data["title"].as(String) + " "
      if entering
        if Terminal.supports_images?
          Colorize.reset
          print "\n\n" + Terminal.show_image(node.data["destination"].as(String)) + "\n"
        else
          # Print as a link
          dest = node.data["destination"].as(String)
          if Terminal.supports_links? || @force_links
            print @style.apply "\n\e]8;;#{dest}\e\\#{node.text}\e]8;;\e\\"
          else
            print @style.apply "\n<#{dest}> #{title}"
          end
        end
      else
        print "\n"
      end
    end

    def item(node : Node, entering : Bool) : Nil
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

    def line_break(node : Node, entering : Bool) : Nil
      print "\n"
    end

    # The `link` method sets the style but doesn't
    # print the link, the children nodes do that.
    #
    # They will get the destination by looking up
    # their parent.
    def link(node : Node, entering : Bool) : Nil
      if entering
        @style << @theme["link"]
      else
        # destination = node.data["destination"].as(String)
        # print @style.apply "<#{destination}>"
        @style.pop
      end
    end

    def list(node : Node, entering : Bool) : Nil
      if entering
        @current_item << node.data["start"].as(Int32) - 1
      else
        @current_item.pop
      end
    end

    def paragraph(node : Node, entering : Bool) : Nil
      if entering && node.parent?.try(&.type) != Node::Type::Item
        print "\n"
      end
    end

    def soft_break(node : Node, entering : Bool) : Nil
      print "\n"
    end

    def strong(node : Node, entering : Bool) : Nil
      if entering
        @style << @theme["strong"]
      else
        @style.pop
      end
    end

    def text(node : Node, entering : Bool) : Nil
      # Skip text rendering inside table cells - we collect it in table_cell
      return if node.parent?.try &.type == Node::Type::TableCell

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
          if Terminal.supports_links? || @force_links
            print @style.apply "\e]8;;#{dest}\e\\#{node.text}\e]8;;\e\\"
          else
            print @style.apply "#{node.text} <#{dest}>"
          end
        end
      else
        print @style.apply node.text
      end
    end

    def thematic_break(node : Node, entering : Bool) : Nil
      if entering
        print "\n\n"
        print @style.apply("-" * 40)
        print "\n"
      end
    end

    def strikethrough(node : Node, entering : Bool) : Nil
      if entering
        @style << @theme["strikethrough"]
      else
        @style.pop
      end
    end

    def alert(node : Node, entering : Bool) : Nil
      # Treat alerts like block quotes for now
      block_quote(node, entering)
    end

    def table(node : Node, entering : Bool) : Nil
      if entering
        @table_data = [] of Array(String)
        @table_alignments = [] of String
        print "\n\n"
      else
        render_table
        @table_data = [] of Array(String)
        @table_alignments = [] of String
      end
    end

    def table_row(node : Node, entering : Bool) : Nil
      if entering
        @current_row = [] of String
      else
        @table_data << @current_row
        @current_row = [] of String
      end
    end

    def table_cell(node : Node, entering : Bool) : Nil
      if entering
        # Capture alignment from header cells
        if node.data["heading"]?.try(&.as(Bool)) == true
          align = node.data["align"]?.try(&.as(String)) || ""
          @table_alignments << align
        end
      else
        # Get text from the first child (Text node)
        cell_text = node.first_child?.try(&.text) || ""
        @current_row << @style.apply(cell_text).to_s
      end
    end

    private def render_table
      return if @table_data.empty?

      header = @table_data[0]
      body = @table_data[1..-1]

      table = Tablo::Table.new(body) do |table_builder|
        header.each_with_index do |title, idx|
          align = alignment_to_tablo(@table_alignments[idx]? || "")
          table_builder.add_column(title, body_alignment: align, header_alignment: align) { |row| row[idx] }
        end
      end

      print table.to_s
    end

    private def alignment_to_tablo(align : String) : Tablo::Justify
      case align
      when "left"   then Tablo::Justify::Left
      when "center" then Tablo::Justify::Center
      when "right"  then Tablo::Justify::Right
      else               Tablo::Justify::Left
      end
    end

    def render(document : Node) : String
      super(document, nil).split("\n").map(&.rstrip).join("\n")
    end
  end

  def self.to_term(source : String, options = Options.new,
                   theme : String? = nil, code_theme : String? = nil,
                   force_links : Bool = false) : String
    return "" if source.empty?
    document = Parser.parse(source, options)
    renderer = TermRenderer.new(options, theme, code_theme, force_links)
    renderer.render(document)
  end
end
