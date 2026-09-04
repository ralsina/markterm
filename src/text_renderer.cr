require "markd"

module Markd
  # Shared machinery for renderers that write text output with
  # indentation: the terminal renderer and the markdown renderer.
  # Subclasses implement the node-specific callbacks.
  abstract class TextRenderer < Renderer
    @indent : Array(String) = [] of String
    @current_item : Array(Int32) = [] of Int32
    @in_table_cell = false
    @cell_content = ""
    @trailing_newlines = 0

    def print(s)
      text = s.to_s
      track_trailing_newlines(text)
      @output_io << text.gsub("\n", "\n" + @indent.join)
    end

    # Remember how many newlines the output ends with (capped at 2),
    # so blocks can separate themselves with exactly one blank line
    private def track_trailing_newlines(text : String) : Nil
      trimmed = text.rstrip('\n')
      if trimmed.empty?
        @trailing_newlines = Math.min(@trailing_newlines + text.size, 2)
      else
        @trailing_newlines = Math.min(text.size - trimmed.size, 2)
      end
    end

    # Print newlines so the output ends with exactly one blank line,
    # ready for the next block to start
    private def blank_line : Nil
      print "\n" if @trailing_newlines == 1
      print "\n\n" if @trailing_newlines == 0
    end

    # Print or collect based on whether we're in a table cell
    private def output(s : String)
      if @in_table_cell
        @cell_content += s
      else
        print s
      end
    end

    def list(node : Node, entering : Bool) : Nil
      if entering
        @current_item << node.data["start"].as(Int32) - 1
      else
        @current_item.pop
      end
    end

    def line_break(node : Node, entering : Bool) : Nil
      print "\n"
    end

    def render(document : Node) : String
      # Drop the empty lines the first block prints as separation;
      # only lines without content, so the first line keeps its indent
      super(document, nil).sub(/\A(?:[^\S\n]*\n)+/, "").split("\n").map(&.rstrip).join("\n")
    end
  end
end
