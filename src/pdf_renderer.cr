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
      # then the theme (when set), then user layers — each later block
      # winning on equal specificity.
      def css : String
        layers = [Pdf.style_css(@style)]
        if theme = @theme
          layers << Pdf.theme_css(theme)
        end
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
          size_code = PAGE_SIZES[@page_size.downcase]?
          raise Error.new("unknown page size '#{@page_size}' (expected a4 or letter)") unless size_code
          margin_pt = @margin_mm * 72.0 / 25.4

          errbuf = Bytes.new(512)
          pages = Litepdf.render(html, nil, size_code, margin_pt.to_f32,
            output_path, @base_dir, @header, @footer, background,
            errbuf, errbuf.size, @pageless ? 1 : 0)
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
    end
  end
end
