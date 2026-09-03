require "markd"

require "./cli"

# Render markdown to PDF: markdown -> HTML (markd) -> litehtml layout ->
# libharu PDF, via the C++ shim in ext/ (built with `make -C ext`).
# Link order matters for static builds (archives resolve in a single
# pass), and the compiler emits @[Link] directives in reverse declaration
# order: litepdf, then libhpdf (searched in ext/build), then zlib/libpng
# for libharu's PNG support, then libstdc++ for the C++ shim.
@[Link(ldflags: "-lstdc++")]
@[Link(ldflags: "-lpng -lz")]
@[Link("hpdf", ldflags: "-L #{__DIR__}/../ext/build")]
@[Link("litepdf")]
lib Litepdf
  fun render = litepdf_render(html : LibC::Char*, css : LibC::Char*, page_size : LibC::Int,
                              margin_pt : LibC::Float, out_path : LibC::Char*, base_dir : LibC::Char*,
                              errbuf : LibC::Char*, errbuf_len : LibC::Int) : LibC::Int
  fun register_font = litepdf_register_font(ttf_path : LibC::Char*, errbuf : LibC::Char*,
                                            errbuf_len : LibC::Int) : LibC::Int
  fun set_emoji_font = litepdf_set_emoji_font(ttf_path : LibC::Char*, errbuf : LibC::Char*,
                                              errbuf_len : LibC::Int) : LibC::Int
end

module Markd
  module Pdf
    class Error < Exception
    end

    # Page sizes understood by the shim
    PAGE_SIZES = {"a4" => 0, "letter" => 1}

    # Print-oriented default stylesheet, written against the CSS subset
    # litehtml supports (no CSS variables, no grid). Pico-inspired: clean
    # typographic scale, subtle rules, shaded code.
    DEFAULT_CSS = <<-CSS
      body { font-family: "DejaVu Sans", Helvetica, Arial, sans-serif; font-size: 11px; line-height: 1.5; color: #1a1a1a; }
      h1 { font-size: 25px; font-weight: bold; margin: 20px 0 12px 0; }
      h2 { font-size: 19px; font-weight: bold; margin: 18px 0 10px 0; }
      h3 { font-size: 15px; font-weight: bold; margin: 16px 0 8px 0; }
      h4 { font-size: 12px; font-weight: bold; margin: 14px 0 8px 0; }
      h5 { font-size: 11px; font-weight: bold; margin: 12px 0 6px 0; }
      h6 { font-size: 11px; font-weight: bold; color: #555555; margin: 12px 0 6px 0; }
      p { margin: 0 0 9px 0; }
      a { color: #0645ad; }
      strong { font-weight: bold; }
      em { font-style: italic; }
      del { text-decoration: line-through; }
      ul, ol { margin: 0 0 9px 0; }
      li { margin: 0 0 3px 0; }
      blockquote { border-left: 3px solid #cccccc; margin: 9px 0 9px 4px; padding: 2px 0 2px 12px; color: #444444; }
      blockquote p { margin: 0 0 6px 0; }
      pre { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #f6f6f6; border: 1px solid #e0e0e0;
            margin: 9px 0 9px 0; padding: 7px 9px 7px 9px; }
      code { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #f2f2f2; padding: 0px 2px 0px 2px; }
      pre code { background-color: #f6f6f6; }
      table { border-spacing: 0; margin: 9px 0 9px 0; font-size: 10.5px; }
      th { font-weight: bold; border: 1px solid #cccccc; background-color: #f2f2f2; padding: 4px 8px 4px 8px; text-align: left; }
      td { border: 1px solid #cccccc; padding: 4px 8px 4px 8px; }
      hr { border-bottom: 1px solid #bbbbbb; margin: 18px 0 18px 0; }
      img { margin: 6px 0 6px 0; }
      .alert { border: 1px solid #bbbbbb; border-left: 4px solid #666666; padding: 8px 12px 4px 12px; margin: 9px 0 9px 0; }
      .alert p { margin: 0 0 6px 0; }
      .alert-title { font-weight: bold; }
      .alert-note { border-left: 4px solid #2e6f9e; }
      .alert-tip { border-left: 4px solid #2e9e5b; }
      .alert-important { border-left: 4px solid #7e4fd0; }
      .alert-warning { border-left: 4px solid #d0962e; }
      .alert-caution { border-left: 4px solid #d0342c; }
      .footnotes { border-top: 1px solid #bbbbbb; margin-top: 18px; font-size: 10px; color: #444444; }
      CSS

    @@css = DEFAULT_CSS

    # Extend or replace the default stylesheet (e.g. from a --css flag).
    def self.css=(user_css : String)
      @@css = DEFAULT_CSS + "\n" + user_css
    end

    def self.css : String
      @@css
    end

    def self.reset_css : Nil
      @@css = DEFAULT_CSS
    end

    # Register a TTF file as a font candidate for font-family matching.
    # Provided fonts take priority over the system fonts the shim scans
    # automatically. Raises Error when the file is not a usable TrueType.
    def self.register_font(path : String) : Nil
      errbuf = Bytes.new(512)
      if Litepdf.register_font(path, errbuf, errbuf.size) == 0
        message = String.new(errbuf).strip
        raise Error.new(message.empty? ? "could not load font '#{path}'" : message)
      end
    end

    # Designate the emoji/symbol fallback font used for emoji codepoints
    # the primary font lacks. When never called, well-known system symbol
    # fonts are probed automatically.
    def self.emoji_font=(path : String) : Nil
      errbuf = Bytes.new(512)
      if Litepdf.set_emoji_font(path, errbuf, errbuf.size) == 0
        message = String.new(errbuf).strip
        raise Error.new(message.empty? ? "could not use '#{path}' as emoji font" : message)
      end
    end

    # Render markdown source to a PDF file, returns the page count.
    def self.render(source : String, output_path : String, options : Markd::Options = Markd::Options.new,
                    page_size : String = "a4", margin_mm : Float64 = 20.0, base_dir : String = ".") : Int32
      html = document_html(Markd.to_html(source, options))
      size_code = PAGE_SIZES[page_size.downcase]?
      if size_code.nil?
        raise Error.new("unknown page size '#{page_size}' (expected a4 or letter)")
      end
      margin_pt = margin_mm * 72.0 / 25.4

      errbuf = Bytes.new(512)
      pages = Litepdf.render(html, nil, size_code, margin_pt.to_f32,
        output_path, base_dir, errbuf, errbuf.size)
      if pages < 0
        message = String.new(errbuf).strip
        raise Error.new(message.empty? ? "PDF rendering failed" : message)
      end
      pages
    end

    # Wrap rendered HTML in a document skeleton with the stylesheet.
    def self.document_html(body_html : String, title : String? = nil) : String
      <<-HTML
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>#{title || document_title(body_html)}</title>
        <style>
        #{css}
        </style>
        </head>
        <body>
        #{body_html}
        </body>
        </html>
        HTML
    end

    # The first heading's text, used as the PDF document title.
    private def self.document_title(body_html : String) : String
      if match = body_html.match(/<h[1-6][^>]*>(.*?)<\/h[1-6]>/m)
        match[1].gsub(/<[^>]*>/, "").strip
      else
        "Untitled"
      end
    end
  end
end
