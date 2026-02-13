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
    @in_table_cell = false
    @cell_content = ""

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

    # Print or collect based on whether we're in a table cell
    # When collecting for table cells, strip ANSI codes to avoid width calculation issues
    private def output(s : String)
      if @in_table_cell
        @cell_content += strip_ansi(s)
      else
        print s
      end
    end

    # Check if any ancestor is a table cell
    private def inside_table_cell?(node : Node) : Bool
      parent = node.parent?
      while parent
        return true if parent.type == Node::Type::TableCell
        parent = parent.parent?
      end
      false
    end

    # Strip ANSI escape codes from a string (for table cell width calculation)
    private def strip_ansi(str : String) : String
      str.gsub(/\e\[[0-9;]*[mGKH]/, "")
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
        output @style.apply(node.text).to_s
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

    # The `link` method sets the style and prints the destination
    # on exit (for non-OSC8 links). The text nodes print the link text.
    def link(node : Node, entering : Bool) : Nil
      if entering
        @style << @theme["link"]
        # Output style codes at the start of the link
        output @style.prefix
      else
        # Print destination after all text nodes (for non-OSC8 links)
        unless Terminal.supports_links? || @force_links
          dest = node.data["destination"].as(String)
          # Get the full text of the link to check if it's a bare URL
          link_text = node.first_child?.try(&.text) || ""
          next_child = node.first_child?.try(&.next?)
          # Only print destination if it's not the same as the text (not a bare URL)
          # If there's a next child, the text is split so it's not a bare URL match
          if dest != link_text || next_child
            output " <#{dest}>"
          end
        end
        @style.pop
        # Reset style at the end of the link (skip if inside table cell)
        output "\e[0m" unless @in_table_cell
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
      if node.parent?.try &.type == Node::Type::Link
        # The parent node is a link, so we need to handle specially.
        # Style is already set by link() method, so just print raw text
        dest = node.parent.data["destination"].as(String)
        if dest == node.text
          # This is a bare URL, just print it.
          output "<#{dest}>"
        else
          # This is a link with text.
          if Terminal.supports_links? || @force_links
            # For OSC 8 links, wrap the text in the link
            output "\e]8;;#{dest}\e\\#{node.text}\e]8;;\e\\"
          else
            # Print just the text, destination is printed by link() on exit
            output node.text
          end
        end
      else
        output @style.apply(node.text).to_s
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
        @in_table_cell = true
        @cell_content = ""
      else
        @in_table_cell = false
        # Use collected cell content, or fall back to text from first child
        cell_text = @cell_content.empty? ? (node.first_child?.try(&.text) || "") : @cell_content
        @current_row << cell_text
        @cell_content = ""
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

      # Use pack with autosize to fit columns to their content
      table.pack(autosize: true)
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
