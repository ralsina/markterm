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
require "./pdf_styles"
require "./pdf_renderer"
require "./math_render"
require "./hyphenation"

# Render markdown to PDF: markdown -> HTML (markd) -> litehtml layout ->
# libharu PDF, via the C++ shim in ext/ (built with `make -C ext`).
# Link order matters for static builds (archives resolve in a single
# pass), and the compiler emits @[Link] directives in reverse declaration
# order: litepdf, then libhpdf (searched in ext/build), then zlib/libpng
# for libharu's PNG support, then the C++ runtime for the C++ shim
# (macOS ships no libstdc++; libc++ is its C++ runtime).
{% if flag?(:darwin) %}
  @[Link(ldflags: "-lc++")]
{% else %}
  @[Link(ldflags: "-lstdc++")]
{% end %}
@[Link(ldflags: "-lpng -lz")]
@[Link("hpdf", ldflags: "-L #{__DIR__}/../ext/build")]
@[Link("litepdf")]
lib Litepdf
  fun render = litepdf_render(html : LibC::Char*, css : LibC::Char*, page_width_mm : LibC::Float,
                              page_height_mm : LibC::Float, margin_top : LibC::Float, margin_right : LibC::Float,
                              margin_bottom : LibC::Float, margin_left : LibC::Float, margin_gutter : LibC::Float,
                              out_path : LibC::Char*, base_dir : LibC::Char*, header : LibC::Char*,
                              footer : LibC::Char*, page_background : LibC::Char*, errbuf : LibC::Char*,
                              errbuf_len : LibC::Int, single_page : LibC::Int, kdp : LibC::Int) : LibC::Int
  fun render_to_memory = litepdf_render_to_memory(html : LibC::Char*, css : LibC::Char*,
                                                  page_width_mm : LibC::Float, page_height_mm : LibC::Float,
                                                  margin_top : LibC::Float, margin_right : LibC::Float,
                                                  margin_bottom : LibC::Float, margin_left : LibC::Float,
                                                  margin_gutter : LibC::Float, base_dir : LibC::Char*,
                                                  header : LibC::Char*, footer : LibC::Char*,
                                                  page_background : LibC::Char*, errbuf : LibC::Char*,
                                                  errbuf_len : LibC::Int, single_page : LibC::Int, kdp : LibC::Int,
                                                  out_data : LibC::Char**, out_len : LibC::SizeT*) : LibC::Int
  fun free_buffer = litepdf_free_buffer(buffer : LibC::Char*)
  fun register_font = litepdf_register_font(ttf_path : LibC::Char*, errbuf : LibC::Char*,
                                            errbuf_len : LibC::Int) : LibC::Int
  fun set_emoji_font = litepdf_set_emoji_font(ttf_path : LibC::Char*, errbuf : LibC::Char*,
                                              errbuf_len : LibC::Int) : LibC::Int
end

module Markd
  module Pdf
    class Error < Exception
    end

    # Page sizes by name: the ISO 216 A and B series (portrait, in mm)
    # plus the US sizes people keep asking for. Custom sizes pass a
    # "WxH" string in millimeters instead of a name.
    PAGE_SIZES = {
      "a0"     => {841.0, 1189.0},
      "a1"     => {594.0, 841.0},
      "a2"     => {420.0, 594.0},
      "a3"     => {297.0, 420.0},
      "a4"     => {210.0, 297.0},
      "a5"     => {148.0, 210.0},
      "a6"     => {105.0, 148.0},
      "b0"     => {1000.0, 1414.0},
      "b1"     => {707.0, 1000.0},
      "b2"     => {500.0, 707.0},
      "b3"     => {353.0, 500.0},
      "b4"     => {250.0, 353.0},
      "b5"     => {176.0, 250.0},
      "b6"     => {125.0, 176.0},
      "letter" => {215.9, 279.4},
      "legal"  => {215.9, 355.6},
    }

    # Largest page dimension the PDF format allows (14400pt), and a
    # floor small enough that a margin still leaves room to draw.
    MIN_PAGE_DIMENSION =   10.0
    MAX_PAGE_DIMENSION = 5000.0

    # Named sizes for pickers and docs.
    def self.page_size_names : Array(String)
      PAGE_SIZES.keys
    end

    # Page margins in millimeters. The gutter is the binding-edge
    # margin: applied on the left for odd (recto) pages and on the right
    # for even (verso) pages. A negative gutter disables it.
    struct PageMargins
      getter top : Float64, right : Float64, bottom : Float64, left : Float64, gutter : Float64

      def initialize(@top : Float64, @right : Float64, @bottom : Float64, @left : Float64,
                     @gutter : Float64 = -1.0)
      end
    end

    # CSS-style margin shorthand in millimeters: one value (all sides),
    # two (top/bottom, left/right), four (top, right, bottom, left), or
    # five (... plus the gutter for mirrored book margins).
    def self.parse_margins(value : String) : PageMargins
      numbers = value.split(',').map do |part|
        number = part.strip.to_f?
        raise Error.new("invalid margin '" + part.strip + "' in '" + value + "' (expected numbers in mm)") unless number
        number
      end
      case numbers.size
      when 1
        PageMargins.new(numbers[0], numbers[0], numbers[0], numbers[0])
      when 2
        PageMargins.new(numbers[0], numbers[1], numbers[0], numbers[1])
      when 4
        PageMargins.new(numbers[0], numbers[1], numbers[2], numbers[3])
      when 5
        PageMargins.new(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4])
      else
        raise Error.new("margins need 1, 2, 4 or 5 comma-separated values in mm (got " + numbers.size.to_s + ") in '" + value + "'")
      end
    end

    # Resolve a page size: a name from PAGE_SIZES (case-insensitive), or
    # "WxH" for custom sizes. Dimension values under 12 read as inches —
    # "6x9" is the classic trim and nobody prints a 6mm-wide page — and
    # anything from 12 up reads as millimeters ("210x297" is A4).
    # Returns {width_mm, height_mm}; raises Error with a
    # user-presentable message otherwise.
    def self.parse_page_size(value : String) : {Float64, Float64}
      normalized = value.strip.downcase
      if dims = PAGE_SIZES[normalized]?
        return dims
      end
      if match = normalized.match(/^([0-9]+(?:\.[0-9]+)?)x([0-9]+(?:\.[0-9]+)?)$/)
        width, height = match[1].to_f, match[2].to_f
        width = width * 25.4 if width < 12.0 # inches
        height = height * 25.4 if height < 12.0
        if width.in?(MIN_PAGE_DIMENSION..MAX_PAGE_DIMENSION) &&
           height.in?(MIN_PAGE_DIMENSION..MAX_PAGE_DIMENSION)
          return {width, height}
        end
        raise Error.new("custom page size is out of range (#{MIN_PAGE_DIMENSION.to_i}-#{MAX_PAGE_DIMENSION.to_i}mm per side)")
      end
      raise Error.new("unknown page size '#{value}' (expected a name like a4 or letter, or WxH like 6x9 (inches) or 100x200 (mm))")
    end

    # Syntax highlighting theme used when nothing better is known: a
    # classic light style that reads well on the default light page.
    DEFAULT_CODE_THEME = "friendly"

    # True when the source looks like a complete HTML document rather
    # than markdown: such input skips the markdown pipeline entirely.
    def self.html_document?(source : String) : Bool
      stripped = source.lstrip
      stripped.downcase.starts_with?("<!doctype html") || stripped.downcase.starts_with?("<html")
    end

    # The page background declared by the CSS's `body` rules, the last
    # one winning as in CSS. Empty when none is set: the shim then
    # leaves the page white.
    def self.page_background(css : String) : String
      rules = css.scan(/body\s*\{[^}]*background-color\s*:\s*(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)/)
      rules.empty? ? "" : rules.last[1]
    end

    # The built-in stylesheets (including the default one) and the CSS
    # layering machinery live in pdf_styles.cr, required above.

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
        td, th { border-color: #{base.call("base02")}; }
        CSS

    rescue error : Exception
      raise Error.new("could not load theme '#{name}': #{error.message}")
    end

    # Render markdown source to a PDF file in one shot: a convenience
    # that builds a throwaway Renderer. See Pdf::Renderer for the
    # reusable, library-friendly form. header/footer templates support
    # "%p" (page number) and "%t" (total pages); empty strings disable.
    # css is extra CSS layered on top of the style (last declaration
    # wins). The theme sets colors when tartrazine knows its name;
    # code_theme picks the syntax-highlighting theme explicitly.
    # pageless produces a single page as tall as the document (good
    # for on-screen viewing, wrong for printing); headers and footers
    # are ignored in that mode.
    def self.render(source : String, output_path : String, options : Markd::Options = Markd::Options.new,
                    page_size : String = "a4", margin_mm : Float64 = 20.0, base_dir : String = ".",
                    header : String = "", footer : String = "", code_theme : String? = nil,
                    theme : String? = nil, html_input : Bool = false, style : String? = nil,
                    pageless : Bool = false, hyphenate : Bool = false, language : String = "en",
                    css : String? = nil, margins : String? = nil, kdp : Bool = false) : Int32
      renderer = Renderer.new(options: options, style: style || "default", theme: theme,
        code_theme: code_theme, page_size: page_size, margin_mm: margin_mm, margins: margins,
        kdp: kdp, base_dir: base_dir, header: header, footer: footer, html_input: html_input,
        pageless: pageless, hyphenate: hyphenate, language: language)
      renderer.add_css(css) if css
      renderer.render(source, output_path)
    end

    # Render markdown to PDF bytes in memory: a convenience that builds
    # a throwaway Renderer. Same parameters as render, minus the output
    # path — no PDF file is ever written.
    def self.render_to_memory(source : String, options : Markd::Options = Markd::Options.new,
                              page_size : String = "a4", margin_mm : Float64 = 20.0, base_dir : String = ".",
                              header : String = "", footer : String = "", code_theme : String? = nil,
                              theme : String? = nil, style : String? = nil, html_input : Bool = false,
                              pageless : Bool = false, hyphenate : Bool = false, language : String = "en",
                              css : String? = nil, margins : String? = nil, kdp : Bool = false) : Bytes
      renderer = Renderer.new(options: options, style: style || "default", theme: theme, code_theme: code_theme,
        page_size: page_size, margin_mm: margin_mm, margins: margins, kdp: kdp, base_dir: base_dir,
        header: header, footer: footer, html_input: html_input, pageless: pageless,
        hyphenate: hyphenate, language: language)
      renderer.add_css(css) if css
      renderer.render_to_memory(source)
    end

    # Internal: called by Pdf::Renderer. Soft hyphens go in last: they
    # only make sense on the final text,
    # and the math spans the rewriter emits must stay intact. Unknown
    # languages surface as the module's Error type.
    def self.hyphenate_body(body_html : String, hyphenate : Bool, language : String) : String
      return body_html unless hyphenate
      begin
        insert_soft_hyphens(body_html, language)
      rescue error : ArgumentError
        raise Error.new(error.message)
      end
    end

    # GFM task lists: markd emits an <input type="checkbox"> as the
    # first child of the <li>, which litehtml drops entirely, leaving a
    # plain bullet. Rewrite the two exact shapes markd produces
    # (attribute order is fixed by its renderer) into a box glyph; the
    # stylesheet suppresses the bullet, and the literal space markd
    # emits after the input keeps the gap between box and text.
    def self.rewrite_task_lists(html : String) : String
      html
        .gsub(%r{<li><input checked="" disabled="" type="checkbox">},
          %(<li class="task-list-item"><span class="task-box">☑</span>))
        .gsub(%r{<li><input disabled="" type="checkbox">},
          %(<li class="task-list-item"><span class="task-box">☐</span>))
    end

    # Internal: called by Pdf::Renderer. Rewrite <img> sources the shim
    # cannot load itself: remote URLs are
    # fetched, other formats are converted to PNG (crimage), data URIs are
    # decoded. PNG/JPEG files are left alone. Converted files land in
    # temp_dir and are tracked in converted for later cleanup; sources
    # that fail keep working (the image is skipped, with a warning on
    # stderr so broken documents are not silently degraded).
    def self.process_images(html : String, base_dir : String, temp_dir : String,
                            converted : Array(String)) : String
      sources = html.scan(/<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']/).map(&.[1]).uniq!
      return html if sources.empty?
      rewritten = {} of String => String
      sources.each do |source|
        if replacement = image_source(source, base_dir, temp_dir, converted)
          STDERR.puts "img #{source[0, 40]} -> #{replacement} (converted: #{converted.size})" if ENV["LITEPDF_DEBUG"]?
          rewritten[source] = replacement
        else
          STDERR.puts "markpdf: could not load image '#{source[0, 80]}', skipping it"
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
        return unless fetch_remote_images?
        return rasterize_image(source, source, temp_dir, converted) if source.downcase.includes?(".svg")
        bytes = fetch_image(source)
        return unless bytes
        return passthrough_or_convert(bytes, temp_dir, converted)
      end
      path = File.expand_path(source, base_dir)
      return unless File.file?(path)
      return path if {".png", ".jpg", ".jpeg"}.includes?(File.extname(path).downcase)
      return rasterize_image(path, path, temp_dir, converted) if path.downcase.ends_with?(".svg")
      convert_to_png(path, temp_dir, converted)
    end

    # Rasterize an image with an external tool (rsvg-convert for SVGs,
    # ImageMagick for WebP and anything else the in-process decoder
    # rejects), mirroring how markterm optionally uses timg for terminal
    # images. Tools disagree on how to name the output file (rsvg-convert
    # takes -o, ImageMagick expects it as the last argument), so each
    # candidate gets its own CLI and the first that succeeds wins.
    private def self.rasterize_image(source : String, local_path : String, temp_dir : String,
                                     converted : Array(String)) : String?
      png_path = File.join(temp_dir, "img#{converted.size}.png")
      svg = local_path.downcase.ends_with?(".svg")
      candidates = svg ? ["rsvg-convert", "magick", "convert"] : ["magick", "convert"]
      candidates.each do |name|
        tool = Process.find_executable(name) || next
        args = name == "rsvg-convert" ? [local_path, "-o", png_path] : [local_path, png_path]
        ok = Process.run(tool, args, output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?
        if ok && File.file?(png_path) && File.size(png_path) > 0
          converted << png_path
          return png_path
        end
      end
      nil
    rescue
      nil
    end

    private def self.data_uri_image(source : String, temp_dir : String, converted : Array(String)) : String?
      header, _, payload = source.partition(",")
      return if payload.nil? || payload.empty?
      return unless header.match(/data:image\/(png|jpeg|jpg|gif|bmp|webp)/i)
      convert_to_png_bytes(Base64.decode(payload), temp_dir, converted)
    rescue
      nil
    end

    # Remote image bodies larger than this are refused (MARKPDF_MAX_IMAGE_MB
    # overrides the 8 MB default).
    MAX_IMAGE_BYTES = (ENV["MARKPDF_MAX_IMAGE_MB"]?.try(&.to_i?) || 8) * 1024 * 1024

    # Whether http(s) image sources are fetched and embedded. The CLI
    # leaves this on; the web playground turns it off, because
    # untrusted markdown must not make the server talk to the network
    # (when it is on, image_fetch_allowed? still gates every request).
    @@fetch_remote_images = true

    def self.fetch_remote_images=(value : Bool)
      @@fetch_remote_images = value
    end

    def self.fetch_remote_images? : Bool
      @@fetch_remote_images
    end

    # Server-side fetches (the web playground renders untrusted markdown)
    # must only reach public http(s) hosts: loopback, private ranges and
    # link-local addresses — cloud metadata lives at 169.254.169.254 —
    # would turn the renderer into a prober of the machine it runs on.
    # Hostnames resolve (3s timeout, fail closed) and every answer must
    # be public; a DNS rebinding race between check and fetch is accepted.
    def self.image_fetch_allowed?(url : String) : Bool
      uri = URI.parse(url)
      return false unless {"http", "https"}.includes?(uri.scheme.try(&.downcase))
      host = uri.host
      return false unless host
      return false if host.empty?
      begin
        Socket::Addrinfo.resolve(host, uri.port || (uri.scheme == "https" ? 443 : 80),
          type: Socket::Type::STREAM, timeout: 3.seconds).each do |addrinfo|
          return false if unsafe_ip?(addrinfo.ip_address)
        end
      rescue Socket::Error
        return false
      end
      true
    end

    # Addresses a server-side fetcher must never touch.
    def self.unsafe_ip?(ip : Socket::IPAddress) : Bool
      unsafe_ip?(ip.address)
    end

    def self.unsafe_ip?(ip : String) : Bool
      ip.includes?(":") ? unsafe_ipv6?(ip) : unsafe_ipv4?(ip)
    end

    # {first octet, range of allowed second octets or nil for "any"}:
    # this-network, RFC1918, loopback, link-local (cloud metadata),
    # CGNAT, and anything at or above multicast.
    private UNSAFE_V4_PREFIXES = [
      {0, nil},
      {10, nil},
      {127, nil},
      {169, 254..254},
      {172, 16..31},
      {192, 168..168},
      {100, 64..127},
    ]

    private def self.unsafe_ipv4?(ip : String) : Bool
      values = ip.split(".").compact_map(&.to_i?)
      return true if values.size != 4
      return true if values[0] >= 224
      first, second = values[0], values[1]
      UNSAFE_V4_PREFIXES.any? do |prefix, range|
        prefix == first && (range.nil? || second.in?(range))
      end
    end

    private def self.unsafe_ipv6?(ip : String) : Bool
      normalized = ip.downcase
      return true if {"::", "::1"}.includes?(normalized)
      return true if normalized.starts_with?("::ffff:")
      first = normalized.split(":").reject(&.empty?).first?.try(&.to_i?(16))
      return true if first && ((0xfc00..0xfdff).covers?(first) ||
                     (0xfe80..0xfebf).covers?(first) ||
                     (0xff00..0xffff).covers?(first))
      false
    rescue
      true
    end

    private def self.fetch_image(url : String) : Bytes?
      uri = URI.parse(url)
      3.times do
        # Redirects come back through here, so every hop is re-validated.
        return unless image_fetch_allowed?(uri.to_s)
        client = HTTP::Client.new(uri)
        client.read_timeout = 15.seconds
        client.connect_timeout = 15.seconds
        begin
          response = client.get(uri.request_target)
          STDERR.puts "fetch status=#{response.status}" if ENV["LITEPDF_DEBUG"]?
          case response.status
          when .redirection?
            location = response.headers["Location"]?
            return unless location
            uri = URI.parse(location)
          when .success?
            return read_capped(response.body_io, MAX_IMAGE_BYTES)
          else
            return
          end
        rescue e
          STDERR.puts "fetch EXC #{e.class}: #{e.message}" if ENV["LITEPDF_DEBUG"]?
          return
        ensure
          client.close
        end
      end
      nil
    rescue
      nil
    end

    # One byte past the cap is read to detect an oversized body; it is
    # then dropped rather than passed on.
    private def self.read_capped(io : IO, cap : Int) : Bytes?
      memory = IO::Memory.new
      copied = IO.copy(io, memory, cap + 1)
      return if copied > cap
      memory.to_slice
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
      return ".png" if bytes[0, 4] == "\x89PNG".to_slice
      return ".jpg" if bytes[0] == 0xFF && bytes[1] == 0xD8
      return ".gif" if bytes[0, 3] == "GIF".to_slice
      return ".bmp" if bytes[0, 2] == "BM".to_slice
      return ".webp" if bytes[0, 4] == "RIFF".to_slice && bytes[8, 4] == "WEBP".to_slice
      return ".tiff" if bytes[0, 4] == "II*\x00".to_slice || bytes[0, 4] == "MM\x00*".to_slice
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
      # CrImage could not decode it (WebP, exotic formats): try the
      # external rasterizer before giving up on the image.
      rasterize_image(source_path, source_path, temp_dir, converted)
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
    def self.document_html(body_html : String, css : String, title : String? = nil,
                           extra_css : String? = nil) : String
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
