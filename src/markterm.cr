require "colorize"

macro def_method(name)
  def {{name}}(node : Node, entering : Bool)
    if entering
      @output_io << "{{name}}\n"
    end
  end
end

module Markd
  class TermRenderer < Renderer
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
    def_method link
    def_method list
    def_method paragraph
    def_method soft_break
    def_method strong
    def_method text
    def_method thematic_break
  end

  def self.to_term(source : String, options = Options.new) : String
    p! "to_term"
    return "" if source.empty?
    document = Parser.parse(source, options)
    renderer = TermRenderer.new(options)
    renderer.render(document)
  end
end
