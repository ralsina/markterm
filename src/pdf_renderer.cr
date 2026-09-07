# The library entry point for rendering PDFs.
#
# A Renderer owns every option as instance state: instances are
# independent, nothing accumulates between renders, and the same
# instance can render many documents. The only process-wide state is
# the font cache (Markd::Pdf.register_font and Markd::Pdf.emoji_font=),
# which persists by design because parsing font metadata is expensive;
# register_font ignores duplicates.
module Markd
  module Pdf
    class Renderer
      getter options, style, theme, code_theme, page_size, margin_mm, base_dir,
        header, footer, html_input, pageless, hyphenate, language, css_layers

      def initialize(@options : Options = Options.new, @style : String = "default",
                     @theme : String? = nil, @code_theme : String? = nil,
                     @page_size : String = "a4", @margin_mm : Float64 = 20.0,
                     @margins : String? = nil, @kdp : Bool = false,
                     @mirror_headers : Bool = false,
                     @base_dir : String = ".", @header : String = "",
                     @footer : String = "", @html_input : Bool = false,
                     @pageless : Bool = false, @hyphenate : Bool = false,
                     @language : String = "en", @css_layers : Array(String) = [] of String)
        # Raises Error on an unknown name: misconfiguration surfaces at
        # construction instead of at first render
        Pdf.style_css(@style)
      end

      # Layer extra CSS on top of the style (later layers win on equal
      # specificity, like repeated --css flags in the CLI).
      def add_css(css : String) : Nil
        @css_layers << css
      end

      # The complete stylesheet this renderer uses: the built-in style,
      # then the theme (when set), then the kdp production layer, then
      # user layers — each later block winning on equal specificity.
      def css : String
        layers = [Pdf.style_css(@style)]
        if theme = @theme
          layers << Pdf.theme_css(theme)
        end
        layers << Pdf::KDP_CSS if @kdp
        layers.concat(@css_layers)
        layers.join("\n")
      end

      # Render markdown — or a complete HTML document — to output_path.
      # Returns the page count; raises Markd::Pdf::Error on failure.
      def render(source : String, output_path : String) : Int32
        temp_dir = File.join(Dir.tempdir, "markpdf-imgs-#{Process.pid}-#{Time.utc.to_unix_ms}")
        Dir.mkdir(temp_dir, 0o700)
        converted = [] of String
        begin
          geometry = prepare(source, temp_dir, converted)
          errbuf = Bytes.new(512)
          pages = Litepdf.render(geometry[:html], nil, geometry[:width_mm].to_f32,
            geometry[:height_mm].to_f32, geometry[:margin_top].to_f32,
            geometry[:margin_right].to_f32, geometry[:margin_bottom].to_f32,
            geometry[:margin_left].to_f32, geometry[:margin_gutter].to_f32, output_path,
            @base_dir, @header, @footer, geometry[:background], errbuf, errbuf.size,
            @pageless ? 1 : 0, @kdp ? 1 : 0, @mirror_headers ? 1 : 0)
          if pages < 0
            message = String.new(errbuf).strip
            raise Error.new(message.empty? ? "PDF rendering failed" : message)
          end
          pages
        ensure
          converted.each { |path| File.delete?(path) }
          begin
            Dir.delete(temp_dir)
          rescue File::Error
          end
        end
      end

      # Render markdown — or a complete HTML document — to bytes in
      # memory: no PDF file is ever written. Only images that need
      # converting pass through a private temp directory, deleted right
      # after the render. Raises Markd::Pdf::Error on failure.
      def render_to_memory(source : String) : Bytes
        temp_dir = File.join(Dir.tempdir, "markpdf-imgs-#{Process.pid}-#{Time.utc.to_unix_ms}")
        Dir.mkdir(temp_dir, 0o700)
        converted = [] of String
        begin
          out_data = Pointer(LibC::Char).null
          out_len = LibC::SizeT.new(0)
          geometry = prepare(source, temp_dir, converted)
          errbuf = Bytes.new(512)
          pages = Litepdf.render_to_memory(geometry[:html], nil, geometry[:width_mm].to_f32,
            geometry[:height_mm].to_f32, geometry[:margin_top].to_f32,
            geometry[:margin_right].to_f32, geometry[:margin_bottom].to_f32,
            geometry[:margin_left].to_f32, geometry[:margin_gutter].to_f32, @base_dir,
            @header, @footer, geometry[:background], errbuf, errbuf.size,
            @pageless ? 1 : 0, @kdp ? 1 : 0, @mirror_headers ? 1 : 0,
            pointerof(out_data), pointerof(out_len))
          if pages < 0
            message = String.new(errbuf).strip
            raise Error.new(message.empty? ? "PDF rendering failed" : message)
          end
          bytes = Slice.new(out_data, out_len.to_i).dup
          Litepdf.free_buffer(out_data)
          bytes
        ensure
          converted.each { |path| File.delete?(path) }
          begin
            Dir.delete(temp_dir)
          rescue File::Error
          end
        end
      end

      # Everything both render methods share: markdown or HTML in, final
      # document HTML out, with images materialized into temp_dir and the
      # page geometry resolved.
      private def prepare(source : String, temp_dir : String,
                          converted : Array(String)) : NamedTuple(
        html: String, width_mm: Float64, height_mm: Float64,
        margin_top: Float64, margin_right: Float64, margin_bottom: Float64,
        margin_left: Float64, margin_gutter: Float64, background: String)
        highlighted_theme = @code_theme || Pdf.tartrazine_known_theme?(@theme) || Pdf::DEFAULT_CODE_THEME
        formatter = Tartrazine::Html.new(
          theme: Tartrazine.theme(highlighted_theme),
          line_numbers: false,
          standalone: false,
        )
        # Complete HTML documents bring their own styles, so the page
        # background (scraped from the CSS body rule) only applies to
        # markdown and HTML fragments.
        is_html = @html_input || Pdf.html_document?(source)
        background = is_html ? "" : Pdf.page_background(css)
        if is_html
          # No markdown processing, no skeleton: the document keeps
          # its own styles and title.
          html = Pdf.process_images(source, @base_dir, temp_dir, converted)
        else
          body_html = Pdf.process_images(MathRender.rewrite_html(Pdf.rewrite_task_lists(Markd.to_html(source, @options, formatter: formatter))), @base_dir, temp_dir, converted)
          body_html = Pdf.hyphenate_body(body_html, @hyphenate, @language)
          html = Pdf.document_html(body_html, css, extra_css: formatter.style_defs)
        end
        page_width_mm, page_height_mm = Pdf.parse_page_size(@page_size)
        margins = Pdf.parse_margins(@margins || @margin_mm.to_s)
        {
          html:          html,
          width_mm:      page_width_mm,
          height_mm:     page_height_mm,
          margin_top:    margins.top,
          margin_right:  margins.right,
          margin_bottom: margins.bottom,
          margin_left:   margins.left,
          margin_gutter: margins.gutter,
          background:    background,
        }
      end
    end
  end
end
