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

    def print(s)
      s = s.to_s.gsub("\n", "\n" + @indent.join)
      @output_io << s
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
      super(document, nil).split("\n").map(&.rstrip).join("\n")
    end
  end
end
