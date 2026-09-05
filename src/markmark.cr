require "./terminal"
require "./styles"
require "./text_renderer"
require "markd"

module Markd
  class MarkRenderer < TextRenderer
    @table_alignments : Array(String) = [] of String
    @current_row : Array(String) = [] of String

    def block_quote(node : Node, entering : Bool) : Nil
      if entering
        print "\n"
        @indent << "> "
      else
        @indent.pop
        print "\n"
      end
    end

    def code(node : Node, entering : Bool) : Nil
      if entering
        output "`#{node.text}`"
      end
    end

    def code_block(node : Node, entering : Bool, formatter : T?) : Nil forall T
      # markd hands plain fences and indented blocks an empty fence
      # language (truthy, splits to an empty array): guard the index.
      language = node.fence_language.try(&.split).try(&.first?)
      print "\n\n```#{language}\n"
      print node.text
      print "```\n\n"
    end

    def emphasis(node : Node, entering : Bool) : Nil
      output "*"
    end

    def heading(node : Node, entering : Bool) : Nil
      if entering
        level = node.data["level"]?.try(&.as(Int32)) || 1
        print "\n\n#{"#" * level} "
      else
        print "\n"
      end
    end

    def html_block(node : Node, entering : Bool) : Nil
      print "\n\n"
      print node.text
    end

    def html_inline(node : Node, entering : Bool) : Nil
      print node.text
    end

    def footnote(node : Node, entering : Bool) : Nil
      if entering
        label = node.data["title"]?.try(&.as(String)) || ""
        output "[^#{label}]"
      end
    end

    def footnote_definition(node : Node, entering : Bool) : Nil
      if entering
        label = node.data["title"]?.try(&.as(String)) || ""
        # Blank line + column 0 marker: the parser only matches
        # definitions on unindented lines. Only the content that
        # follows is indented, which is what continues the definition
        print "\n\n[^#{label}]: "
        @indent << "    "
      else
        @indent.pop
      end
    end

    def image(node : Node, entering : Bool) : Nil
      if entering
        alt = node.first_child?.try(&.text) || ""
        print "![#{alt}](#{node.data["destination"]?.try(&.as(String)) || ""})"
      end
    end

    def item(node : Node, entering : Bool) : Nil
      if entering
        marker =
          case node.data["type"]?
          when "bullet"
            "* "
          when "checkbox"
            # Keep the bullet so the output re-parses as a task list
            bullet = node.data["bullet_char"]?.try(&.as(String)) || "-"
            if node.data["checked"]? == true
              "#{bullet} [x] "
            else
              "#{bullet} [ ] "
            end
          else
            @current_item[-1] += 1
            "#{@current_item[-1]}. "
          end
        print "\n"
        print marker
        @indent << "   "
      else
        @indent.pop
      end
    end

    # The `link` method sets the style but doesn't
    # print the link, the children nodes do that.
    #
    # They will get the destination by looking up
    # their parent.
    def link(node : Node, entering : Bool) : Nil
    end

    def paragraph(node : Node, entering : Bool) : Nil
      if entering
        parent_type = node.parent?.try(&.type)
        case parent_type
        when Node::Type::Item
          # no extra newline
        when Node::Type::FootnoteDefinition
          # The first paragraph follows the [^label]: marker; later
          # ones need a blank line to stay separate paragraphs
          print "\n\n" if node.prev?
        else
          # A blank line between sibling paragraphs (single newlines
          # would glue them into one on re-parse); a lone newline for
          # the first paragraph positions the line and triggers
          # container prefixes like the blockquote's "> ".
          print node.prev? ? "\n\n" : "\n"
        end
      end
    end

    def soft_break(node : Node, entering : Bool) : Nil
      # Keep soft breaks as newlines so documents round-trip
      print "\n"
    end

    def strong(node : Node, entering : Bool) : Nil
      output "**"
    end

    def text(node : Node, entering : Bool) : Nil
      if node.parent?.try &.type == Node::Type::Link
        # The parent node is a link, so we need to handle
        # specially.
        dest = node.parent.data["destination"].as(String)
        if dest == node.text
          # This is a bare URL, just print it.
          output "<#{dest}>"
        else
          # This is a link with text. In some terminals, we can get fancy
          # and show a HTML-style hyperlink.
          output "[#{node.text}](#{dest})"
        end
        # Image nodes already print their children's text
      elsif node.parent?.try &.type != Node::Type::Image
        output node.text
      end
    end

    def thematic_break(node : Node, entering : Bool) : Nil
      if entering
        print "\n\n"
        print "-" * 40
        print "\n"
      end
    end

    def strikethrough(node : Node, entering : Bool) : Nil
      # The text children between the delimiters are printed by the walk
      output "~~"
    end

    def alert(node : Node, entering : Bool) : Nil
      if entering
        label = node.data["alert"]?.try(&.as(String)) || ""
        title = node.data["title"]?.try(&.as(String)) || ""
        @indent << "> "
        marker = title == label || title.empty? ? "[!#{label}]" : "[!#{label}] #{title}"
        print "\n#{marker}"
      else
        @indent.pop
      end
    end

    def table(node : Node, entering : Bool) : Nil
      if entering
        @table_alignments = [] of String
        print "\n\n"
      else
        @table_alignments = [] of String
        print "\n"
      end
    end

    def table_row(node : Node, entering : Bool) : Nil
      if entering
        @current_row = [] of String
      else
        is_header = node.data["heading"]?.try(&.as(Bool)) == true

        print "|"
        @current_row.each { |cell| print " #{cell} |" }
        print "\n"

        if is_header
          print "|"
          @current_row.each_with_index do |_, idx|
            case @table_alignments[idx]? || ""
            when "left"   then print ":--- |"
            when "center" then print ":---:|"
            when "right"  then print " ---:|"
            else               print " --- |"
            end
          end
          print "\n"
        end

        @current_row = [] of String
      end
    end

    def table_cell(node : Node, entering : Bool) : Nil
      if entering
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
  end

  def self.to_md(source : String, options = Options.new) : String
    return "" if source.empty?
    document = Parser.parse(source, options)
    renderer = MarkRenderer.new(options)
    renderer.render(document).strip("\n")
  end
end
