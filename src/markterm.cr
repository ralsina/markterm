require "./terminal"
require "./styles"
require "./text_renderer"
require "./markmark"
require "./math_render"
require "colorize"
require "markd"
require "tablo"

module Markd
  class TermRenderer < TextRenderer
    SGR_OR_OSC8 = /\e\[[0-9;]*[mGKH]|\e\]8;;[^\e]*\e\\/

    # GFM alert accents by type: the same hues the PDF stylesheet uses
    # for its alert left borders, mapped to the terminal's palette.
    ALERT_ACCENTS = {
      "note"      => :blue,
      "tip"       => :green,
      "important" => :magenta,
      "warning"   => :yellow,
      "caution"   => :red,
    }

    @style : Terminal::StyleStack
    @theme : Hash(String, Terminal::Style)
    @code_theme : String?
    @indent = ["  "]
    @force_links = false
    @table_data : Array(Array(String)) = [] of Array(String)
    @table_alignments : Array(String) = [] of String
    @current_row : Array(String) = [] of String
    @cell_placeholders : Array(Tuple(String, String)) = [] of Tuple(String, String)
    @placeholder_index = 0
    @max_width : Int32?
    @block_buffer = ""
    @in_wrappable_block = false
    @image_visible = true

    def initialize(@options = Options.new, theme : String? = nil, code_theme : String? = nil, @force_links : Bool = false, max_width : Int32? = nil)
      super(@options)
      @theme = Terminal.theme(theme)
      @code_theme = code_theme
      @style = Terminal::StyleStack.new
      @style << @theme["default"]
      @max_width = max_width
    end

    # Print or collect based on whether we're in a table cell or wrappable block
    private def output(s : String)
      if @in_table_cell
        @cell_content += s
      elsif @in_wrappable_block && @max_width
        @block_buffer += s
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

    # Strip OSC 8 hyperlink sequences (they don't contribute to visible length)
    private def strip_osc8(str : String) : String
      str.gsub(/\e\]8;;[^\e]*\e\\/, "")
    end

    # Calculate visible length in terminal columns (excluding ANSI codes
    # and OSC 8 hyperlinks, counting East Asian wide glyphs as two columns)
    private def visible_length(str : String) : Int32
      Terminal.display_width(strip_osc8(strip_ansi(str)))
    end

    # True for destinations that are real URLs. Relative paths and
    # anchors read fine as the link's own text; a printed copy of them
    # is noise.
    private def urlish?(destination : String) : Bool
      destination.starts_with?("http://") || destination.starts_with?("https://") ||
        destination.starts_with?("mailto:")
    end

    # Condensed form of a URL for display next to link text: scheme
    # and www. dropped, long paths elided in the middle.
    private def condensed_url(url : String) : String
      text = url.sub(%r{\A[a-z]+://}i, "").sub(/\Awww\./i, "")
      if text.size > 44
        text = "#{text[0, 32]}…#{text[-8, 8]}"
      end
      text
    end

    # The concatenated text of a node's children: Node#text is not
    # populated for container nodes like links, but a bare-URL link's
    # children concatenate to exactly its destination.
    private def full_text(node : Node) : String
      String.build do |io|
        child = node.first_child?
        while child
          io << child.text
          child = child.next?
        end
      end
    end

    # Soft-wrap code lines that would overflow the width: the terminal
    # would hard-wrap them at column zero and destroy the block's
    # shape. Continuations indent two columns past the code's left
    # edge (which print() re-indents, so both indents come out of the
    # budget). No-op when no width is known.
    private def wrap_code(text : String) : String
      return text unless max_width = @max_width
      indent_len = visible_length(@indent.join)
      wrap_width = max_width - indent_len - (indent_len + 2)
      return text if wrap_width <= 4
      continuation = " " * (indent_len + 2)
      text.lines.map do |line|
        next line if visible_length(line) <= wrap_width
        pieces = [] of String
        rest = line
        until rest.empty?
          chunk = rest[0, wrap_width]? || rest
          pieces << chunk
          rest = rest.size > chunk.size ? rest[chunk.size..] : ""
        end
        pieces.join("\n" + continuation)
      end.join("\n")
    end

    # Wrap and print the accumulated block buffer, then clear it
    private def flush_block_buffer
      if (max_width = @max_width) && !@block_buffer.empty?
        wrapped = word_wrap(@block_buffer, max_width, @indent.join)
        print wrapped
      end
      @block_buffer = ""
    end

    # Wrap text to fit within max_width, accounting for indentation
    # Long words overflow rather than break
    private def word_wrap(text : String, max_width : Int32, indent : String) : String
      return text if max_width <= 0

      indent_len = visible_length(indent)
      available = max_width - indent_len
      return text if available <= 0

      lines = [] of String
      current_line = ""

      # Split on whitespace and reassemble with single spaces
      text.split(/\s+/).each do |word|
        next if word.empty?

        word_len = visible_length(word)

        if current_line.empty?
          current_line = word
        elsif visible_length(current_line) + 1 + word_len <= available
          current_line += " " + word
        else
          lines << current_line
          current_line = word
        end
      end
      lines << current_line unless current_line.empty?

      lines.join("\n")
    end

    def block_quote(node : Node, entering : Bool) : Nil
      if entering
        # Push the indent first, so the separator newlines carry the
        # quote bar for the quote's first line
        @indent << "│ "
        blank_line
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
      blank_line
      text = wrap_code(node.text)
      if languages.nil? || languages.empty?
        print text
      else
        print Terminal.highlight(text, languages[0], @code_theme)
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
        level = node.data["level"]?.try(&.as(Int32)) || 1
        blank_line
        # Color, bold and underline already carry the hierarchy; the
        # ATX hashes only matter when no ANSI reaches the terminal.
        marker = @style.prefix.includes?('\e') ? "" : "#{"#" * level} "
        # When wrapping, buffer the prefix so it word-wraps together
        # with the heading text; otherwise print it right away, as
        # the text nodes bypass the buffer when there is no max_width
        if @max_width
          @in_wrappable_block = true
          @block_buffer = @style.apply(marker).to_s
        else
          print @style.apply(marker)
        end
      else
        @in_wrappable_block = false
        flush_block_buffer
        print "\n"
        @style.pop
      end
    end

    def html_block(node : Node, entering : Bool) : Nil
      blank_line
      print Terminal.highlight(node.text, "html", @code_theme)
    end

    def html_inline(node : Node, entering : Bool) : Nil
      print Terminal.highlight(node.text, "html", @code_theme)
    end

    def footnote(node : Node, entering : Bool) : Nil
      if entering
        # References get their number normalized by the parser (1..n
        # in definition order), so [^weird-label] still shows as [2]
        number = node.data["number"]?.try(&.as(Int32)) || 0
        @style << @theme["link"]
        output @style.apply("[#{number}]").to_s
        @style.pop
      end
    end

    # Definitions are moved to the end of the document by the parser,
    # so render a small section header before the first one
    def footnote_definition(node : Node, entering : Bool) : Nil
      if entering
        if node.prev?.try(&.type) != Node::Type::FootnoteDefinition
          blank_line
          print @style.apply("--" * 20)
          print "\n"
          @style << @theme["heading"]
          print @style.apply("Footnotes")
          @style.pop
        end
        number = node.data["number"]?.try(&.as(Int32)) || 0
        print "\n"
        print @style.apply("[#{number}] ")
        @indent << "    "
      else
        @indent.pop
      end
    end

    def image(node : Node, entering : Bool) : Nil
      if entering
        dest = node.data["destination"]?.try(&.as(String)) || ""
        image_data = Terminal.supports_images? ? Terminal.show_image(dest) : ""
        if image_data.empty?
          # Fallback: an image placeholder, hyperlinked when the
          # terminal supports OSC 8. An alt-less image riding inside a
          # link (badges!) would only repeat what the link already
          # says, so it says nothing at all.
          # The alt may be split across several text children (markd
          # splits it), so concatenate them all
          alt = full_text(node).strip
          in_link = node.parent?.try(&.type) == Node::Type::Link
          if !alt.empty? || !in_link
            placeholder = alt.empty? ? "[image]" : "[image: #{alt}]"
            if Terminal.supports_links? || @force_links
              print @style.apply("\n\e]8;;#{dest}\e\\#{placeholder}\e]8;;\e\\")
            else
              print @style.apply("\n#{placeholder}")
            end
            @image_visible = true
          else
            @image_visible = false
          end
        else
          # Reset colors in-band before the image, so the image's own
          # escape sequences start from a clean style. Writing through
          # Colorize.reset would leak to STDOUT outside the result.
          reset_code = Colorize.enabled? ? "\e[0m" : ""
          print "\n\n#{reset_code}#{image_data}\n"
          @image_visible = true
        end
      else
        print "\n" if @image_visible
      end
    end

    def item(node : Node, entering : Bool) : Nil
      if entering
        marker =
          case node.data["type"]?
          when "bullet"
            "• "
          when "checkbox"
            if node.data["checked"]? == true
              "[x] "
            else
              "[ ] "
            end
          else
            @current_item[-1] += 1
            "#{@current_item[-1]}. "
          end
        print "\n"
        print @style.apply("#{marker} ")
        @indent << "   "
      else
        @indent.pop
      end
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
        # Skip URL in table cells to keep visible length correct
        unless Terminal.supports_links? || @force_links || @in_table_cell
          dest = node.data["destination"]?.try(&.as(String)) || ""
          # Only print a destination for real URLs, and then condensed
          # and dim: a full URL breaks the sentence's flow and rarely
          # fits the width anyway. A bare URL is its own destination,
          # and relative destinations read fine as the link's text.
          if dest != full_text(node) && urlish?(dest)
            output " (" + condensed_url(dest).colorize.dim.to_s + ")"
          end
        end
        @style.pop
        # Reset style at the end of the link (skip if inside table cell)
        output "\e[0m" unless @in_table_cell
      end
    end

    def paragraph(node : Node, entering : Bool) : Nil
      if entering
        @in_wrappable_block = true
        @block_buffer = ""
        parent_type = node.parent?.try(&.type)
        if parent_type != Node::Type::Item &&
           parent_type != Node::Type::FootnoteDefinition
          blank_line
        end
      else
        @in_wrappable_block = false
        flush_block_buffer
      end
    end

    def soft_break(node : Node, entering : Bool) : Nil
      if @in_wrappable_block && @max_width
        # Print the buffered text before the break, otherwise word_wrap
        # would collapse the break into a space and reorder the output
        flush_block_buffer
      end
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
        dest = node.parent.data["destination"]?.try(&.as(String)) || ""
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
      elsif node.parent?.try &.type != Node::Type::Image
        # Image nodes print their own placeholder; the alt text child
        # would only duplicate it
        output @style.apply(node.text).to_s
      end
    end

    def thematic_break(node : Node, entering : Bool) : Nil
      if entering
        blank_line
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
      if entering
        # Push the indent first, like block_quote, so the separator
        # newlines carry the bar for the alert's first line. The bar
        # takes the alert's accent color: print() inserts the indent
        # verbatim, ANSI codes and all, and the width math strips them
        # right back out.
        alert_type = node.data["alert"]?.try(&.as(String)) || ""
        bar = if (accent = ALERT_ACCENTS[alert_type.downcase]?)
          "│".colorize.fore(accent).to_s + " "
        else
          "│ "
        end
        @indent << bar
        blank_line
        @style << @theme["block_quote"]
        title = node.data["title"]?.try(&.as(String)) || ""
        print @style.apply("#{title}\n") unless title.empty?
      else
        @indent.pop
        @style.pop
        print "\n"
      end
    end

    def table(node : Node, entering : Bool) : Nil
      if entering
        @table_data = [] of Array(String)
        @table_alignments = [] of String
        blank_line
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

        if cell_text.includes?("\e")
          @current_row << words_to_placeholders(cell_text)
        else
          @current_row << cell_text
        end
        @cell_content = ""
      end
    end

    # Represent a styled cell as placeholder characters so tablo's
    # width math works on visible length. Each whitespace-separated
    # word gets its own marker run, and real spaces are kept between
    # runs, so tablo can wrap the cell at word boundaries.
    private def words_to_placeholders(cell_text : String) : String
      # A part with no visible characters is a pure escape sequence:
      # it terminates the previous word, or opens the next one
      parts = [] of String
      cell_text.split(/\s+/).each do |part|
        next if part.empty?
        if visible_length(part) == 0
          if parts.empty?
            parts << part
          else
            parts[-1] += part
          end
        elsif !parts.empty? && visible_length(parts[-1]) == 0
          parts[-1] += part
        else
          parts << part
        end
      end
      return cell_text if parts.empty?

      result = String::Builder.new
      parts.each_with_index do |part, index|
        result << " " if index > 0
        marker = (0xE000 + @placeholder_index).chr.to_s
        result << marker * visible_length(part)
        @cell_placeholders << {marker * visible_length(part), part}
        @placeholder_index += 1
      end
      result.to_s
    end

    private def render_table
      return if @table_data.empty?

      header = @table_data[0]
      body = @table_data[1..-1]

      table = Tablo::Table.new(body, border: Tablo::Border.new(Tablo::Border::PreSet::Modern)) do |table_builder|
        header.each_with_index do |title, idx|
          align = alignment_to_tablo(@table_alignments[idx]? || "")
          table_builder.add_column(title, body_alignment: align, header_alignment: align) { |row| row[idx] }
        end
      end

      # Size columns to fit their content, then shrink the table to
      # max_width if it overflows. pack's width argument would also
      # widen narrower tables, so only repack when actually too wide.
      table.pack(autosize: true)
      result = table.to_s
      max_width = @max_width
      if max_width
        available = max_width - visible_length(@indent.join)
        if result.split("\n").any? { |line| visible_length(line) > available }
          table.pack(available, autosize: true)
          result = table.to_s
        end
      end

      result = restore_styled_cells(result)

      print result
      @cell_placeholders.clear
      @placeholder_index = 0
    end

    # Replace the placeholder characters with the styled cell content
    # they stand for. Tablo's wrapping may split a placeholder run
    # across lines, so match runs of marker characters and hand each
    # run its share of the styled text, in order.
    private def restore_styled_cells(result : String) : String
      return result if @cell_placeholders.empty?

      offsets = {} of Char => Int32
      @cell_placeholders.each_with_index do |_, index|
        offsets[(0xE000 + index).chr] = 0
      end

      String.build do |builder|
        index = 0
        while index < result.size
          char = result[index]
          if offsets.has_key?(char)
            run_start = index
            while index < result.size && result[index] == char
              index += 1
            end
            styled, offset = @cell_placeholders[char.ord - 0xE000][1], offsets[char]
            builder << styled_fragment(styled, offset, index - run_start)
            offsets[char] = offset + index - run_start
          else
            builder << char
            index += 1
          end
        end
      end
    end

    # Extract a fragment of a styled string: run_length visible
    # characters starting at visible offset, keeping the escape
    # sequences that fall inside the fragment
    private def styled_fragment(styled : String, offset : Int32, run_length : Int32) : String
      fragment = String::Builder.new
      visible_seen = 0
      emitting = false
      index = 0

      while index < styled.size
        char = styled[index]
        if char == '\e'
          sequence = SGR_OR_OSC8.match(styled, index).try(&.[0]) || char.to_s
          fragment << sequence if emitting && visible_seen < offset + run_length
          index += sequence.size
        else
          emitting = true if !emitting && visible_seen == offset
          break if emitting && visible_seen >= offset + run_length
          fragment << char if emitting
          visible_seen += 1
          index += 1
        end
      end
      fragment.to_s
    end

    private def alignment_to_tablo(align : String) : Tablo::Justify
      case align
      when "left"   then Tablo::Justify::Left
      when "center" then Tablo::Justify::Center
      when "right"  then Tablo::Justify::Right
      else               Tablo::Justify::Left
      end
    end
  end

  def self.to_term(source : String, options = Options.new,
                   theme : String? = nil, code_theme : String? = nil,
                   force_links : Bool = false, max_width : Int32? = nil) : String
    return "" if source.empty?
    source = MathRender.rewrite_markdown_math(source)
    document = Parser.parse(source, options)
    renderer = TermRenderer.new(options, theme, code_theme, force_links, max_width)
    renderer.render(document)
  end
end
