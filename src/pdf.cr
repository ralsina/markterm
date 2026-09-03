# Tartrazine must be required before markd: markd checks for the
# constant at compile time to decide whether code blocks get
# syntax-highlighted.
require "tartrazine"
require "tartrazine/formatters/html"
require "markd"
require "sixteen"
require "crimage"
require "http/client"
require "uri"
require "base64"

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
  fun set_page_text = litepdf_set_page_text(header : LibC::Char*, footer : LibC::Char*) : Void
  fun set_page_background = litepdf_set_page_background(css_color : LibC::Char*) : Void
end

module Markd
  module Pdf
    class Error < Exception
    end

    # Page sizes understood by the shim
    PAGE_SIZES = {"a4" => 0, "letter" => 1}

    # Syntax highlighting theme used when nothing better is known: a
    # classic light style that reads well on the default light page.
    DEFAULT_CODE_THEME = "friendly"

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
      pre code { background-color: transparent; }
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

    # Generate CSS rules from a base16/sixteen theme: the palette's
    # foreground and background plus accent colors for headings, links,
    # code and borders. Works for dark and light variants alike.
    # Returns the theme name when tartrazine knows it (it maps many
    # base16/sixteen names directly), nil otherwise.
    def self.tartrazine_known_theme?(name : String?) : String?
      return unless name
      Tartrazine.theme(name)
      name
    rescue
      nil
    end

    def self.theme_css(name : String) : String
      theme = Sixteen.theme(name)
      base = ->(key : String) { "#" + theme[key].hex }
      <<-CSS
        body { color: #{base.call("base05")}; background-color: #{base.call("base00")}; }
        h1, h2, h3, h4, h5, h6 { color: #{base.call("base0D")}; }
        a { color: #{base.call("base0C")}; }
        code { background-color: #{base.call("base01")}; }
        pre { background-color: #{base.call("base01")}; border-color: #{base.call("base02")}; }
        th { background-color: #{base.call("base01")}; }
        td, th { border-color: #{base.call("base02")}; }
        blockquote { border-left-color: #{base.call("base03")}; color: #{base.call("base04")}; }
        hr { border-bottom-color: #{base.call("base03")}; }
        CSS

    rescue error : Exception
      raise Error.new("could not load theme '#{name}': #{error.message}")
    end

    # Render markdown source to a PDF file, returns the page count.
    # header/footer templates support "%p" (page number) and "%t"
    # (total pages); empty strings disable. code_theme picks the
    # tartrazine theme for syntax highlighting: an explicit name, the
    # -t theme name (when tartrazine knows it), or the light-friendly
    # default.
    def self.render(source : String, output_path : String, options : Markd::Options = Markd::Options.new,
                    page_size : String = "a4", margin_mm : Float64 = 20.0, base_dir : String = ".",
                    header : String = "", footer : String = "", code_theme : String? = nil,
                    theme : String? = nil) : Int32
      Litepdf.set_page_text(header, footer)
      # The page background comes from the CSS `body` rule so themes can
      # produce dark pages; the shim paints it before any content.
      body_background = css.match(/body\s*\{[^}]*background-color\s*:\s*(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)/)
      Litepdf.set_page_background(body_background ? body_background[1] : "")
      temp_dir = File.join(Dir.tempdir, "markpdf-imgs-#{Process.pid}-#{Time.utc.to_unix_ms}")
      Dir.mkdir(temp_dir, 0o700)
      converted = [] of String
      begin
        highlighted_theme = code_theme || tartrazine_known_theme?(theme) || DEFAULT_CODE_THEME
        formatter = Tartrazine::Html.new(
          theme: Tartrazine.theme(highlighted_theme),
          line_numbers: false,
          standalone: false,
        )
        body_html = process_images(Markd.to_html(source, options, formatter: formatter), base_dir, temp_dir, converted)
        html = document_html(body_html, extra_css: formatter.style_defs)
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
      ensure
        converted.each { |path| File.delete?(path) }
        begin
          Dir.delete(temp_dir)
        rescue File::Error
        end
      end
    end

    # Rewrite <img> sources the shim cannot load itself: remote URLs are
    # fetched, other formats are converted to PNG (crimage), data URIs are
    # decoded. PNG/JPEG files are left alone. Converted files land in
    # temp_dir and are tracked in converted for later cleanup; sources
    # that fail keep working as before (silently skipped).
    private def self.process_images(html : String, base_dir : String, temp_dir : String,
                                    converted : Array(String)) : String
      sources = html.scan(/<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']/).map(&.[1]).uniq!
      return html if sources.empty?
      rewritten = {} of String => String
      sources.each do |source|
        if replacement = image_source(source, base_dir, temp_dir, converted)
          rewritten[source] = replacement
        end
      end
      return html if rewritten.empty?
      html.gsub(/src\s*=\s*["']([^"']+)["']/) do |match|
        source = $1
        rewritten.has_key?(source) ? "src=\"#{rewritten[source]}\"" : match
      end
    end

    private def self.image_source(source : String, base_dir : String, temp_dir : String,
                                  converted : Array(String)) : String?
      if source.starts_with?("data:image/")
        return data_uri_image(source, temp_dir, converted)
      end
      if source.starts_with?("http://") || source.starts_with?("https://")
        bytes = fetch_image(source)
        return unless bytes
        return passthrough_or_convert(bytes, temp_dir, converted)
      end
      path = File.expand_path(source, base_dir)
      return unless File.file?(path)
      return if {".png", ".jpg", ".jpeg"}.includes?(File.extname(path).downcase)
      convert_to_png(path, temp_dir, converted)
    end

    private def self.data_uri_image(source : String, temp_dir : String, converted : Array(String)) : String?
      header, _, payload = source.partition(",")
      return if payload.nil? || payload.empty?
      return unless header.match(/data:image\/(png|jpeg|jpg|gif|bmp|webp)/i)
      convert_to_png_bytes(Base64.decode(payload), temp_dir, converted)
    rescue
      nil
    end

    private def self.fetch_image(url : String) : Bytes?
      uri = URI.parse(url)
      3.times do
        client = HTTP::Client.new(uri)
        client.read_timeout = 15.seconds
        client.connect_timeout = 15.seconds
        begin
          response = client.get(uri.request_target)
          case response.status
          when .redirection?
            location = response.headers["Location"]?
            return unless location
            uri = URI.parse(location)
          when .success?
            return response.body.to_slice
          else
            return
          end
        ensure
          client.close
        end
      end
      nil
    rescue
      nil
    end

    # libharu loads PNG and JPEG natively; anything else becomes PNG.
    private def self.passthrough_or_convert(bytes : Bytes, temp_dir : String,
                                            converted : Array(String)) : String?
      ext = sniff_image_ext(bytes)
      return unless ext
      return write_temp(bytes, temp_dir, ext, converted) if {".png", ".jpg"}.includes?(ext)
      path = write_temp(bytes, temp_dir, ext, converted)
      return unless path
      convert_to_png(path, temp_dir, converted)
    end

    private def self.sniff_image_ext(bytes : Bytes) : String?
      return if bytes.size < 12
      return ".png" if bytes[0, 4] == "\x89PNG".bytes
      return ".jpg" if bytes[0] == 0xFF && bytes[1] == 0xD8
      return ".gif" if bytes[0, 3] == "GIF".bytes
      return ".bmp" if bytes[0, 2] == "BM".bytes
      return ".webp" if bytes[0, 4] == "RIFF".bytes && bytes[8, 4] == "WEBP".bytes
      return ".tiff" if bytes[0, 4] == "II*\x00".bytes || bytes[0, 4] == "MM\x00*".bytes
      nil
    end

    private def self.write_temp(bytes : Bytes, temp_dir : String, ext : String, converted : Array(String)) : String
      path = File.join(temp_dir, "img#{converted.size}#{ext}")
      File.write(path, bytes, mode: "wb")
      converted << path
      path
    end

    private def self.convert_to_png(source_path : String, temp_dir : String, converted : Array(String)) : String?
      # Normalize any decoded variant to RGBA via the pipeline: PNG.write
      # only handles concrete image types.
      image = CrImage::Pipeline.new(CrImage.read(source_path)).result
      png_path = File.join(temp_dir, "img#{converted.size}.png")
      CrImage.write(png_path, image)
      converted << png_path
      png_path
    rescue
      nil
    end

    private def self.convert_to_png_bytes(bytes : Bytes, temp_dir : String,
                                          converted : Array(String)) : String?
      ext = sniff_image_ext(bytes)
      return unless ext
      path = write_temp(bytes, temp_dir, ext, converted)
      return unless path
      convert_to_png(path, temp_dir, converted)
    end

    # Wrap rendered HTML in a document skeleton with the stylesheet.
    def self.document_html(body_html : String, title : String? = nil, extra_css : String? = nil) : String
      <<-HTML
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>#{title || document_title(body_html)}</title>
        <style>
        #{css}
        #{extra_css}
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
