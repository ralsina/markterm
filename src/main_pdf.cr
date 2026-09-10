require "./pdf"
require "./cli"
require "docopt-config"
require "markd"

doc = <<-DOC
  Markpdf - A tool to render markdown to PDF

  Usage:
    markpdf [<file>] [--font <font>...][--css <css>...][options]
    markpdf --list-styles
    markpdf -h | --help
    markpdf --version

  Options:
    -h --help                  Show this screen.
    -t <theme>, --theme <theme>  Theme to use for coloring output
    --code-theme <code-theme>  Theme to use for coloring code blocks
    --version                  Show version.
    -o <output>, --output <output>  Write the PDF to a file (defaults to standard output)
    --page-size <size>         Page size: a0..a6, b0..b6, letter, legal, or
                               custom WxH with an optional unit per side
                               (6x9 or 6x9in = 152.4x228.6mm, 100x200mm)
                               [default: a4]
    --margin <margins>         Page margins in mm, CSS-style: 1 value (all sides),
                               2 (top/bottom, left/right), 4 (top, right, bottom,
                               left) or 5 (... plus gutter) [default: 20]
    --mirror-headers           Mirror running headers and footers on verso
                               (even) pages — pairs with a gutter margin
    --kdp                      KDP print mode: embed every font, drop the
                               outline, scrub metadata, size the gutter
                               from the page count (unless --margin sets
                               one), start chapters on recto pages and
                               pad odd page counts to even
    --style <style>            Built-in stylesheet setting layout and typography
                               (themes set colors instead): see --list-styles
                               [default: default]
    --list-styles              List the built-in stylesheets and exit
    --print-style              Print the built-in stylesheet named by --style to
                               standard output and exit
    --css <css>                Extra CSS file layered on top of the style; last
                               declaration wins (may be repeated)
    --font <font>              TTF font file to embed (can be repeated). Fonts are
                               matched by their internal family name; system fonts
                               are used automatically when available.
    --emoji-font <font>        TTF font used for emoji and symbols the main fonts
                               lack (auto-detected from system fonts by default)
    --header <header>          Page header text; "%p" is the page number, "%t"
                               the total page count. Split it with "|" into
                               left|center|right sections
    --footer <footer>          Page footer text; supports the same placeholders
                               and sections
    --pageless                 Single-page output: one page as tall as the document,
                               no headers/footers — good for on-screen reading,
                               wrong for printing. Very long documents scale
                               down to fit the PDF page-size limit.
    --hyphenate                Insert soft hyphens at hyphenation points, so
                               fully justified paragraphs can break long words
                               with a hyphen at the line end
    --language <language>      Hyphenation language for --hyphenate: en or es
                               [default: en]
    --no-remote-images         Skip http(s) image sources instead of fetching
                               them; remote fetching can also be turned off
                               programmatically with Markd::Pdf
    --toc                      Prepend a table of contents with page numbers;
                               every entry links to its section. The layout
                               runs repeatedly until the numbers stop moving
                               (a TOC's own length shifts the pages it points to)
    --toc-depth <depth>        Deepest heading level the TOC lists, or a
                               range N-M listing only levels N through M
                               (2-6 skips a level-1 document title);
                               levels run 1 to 6 [default: 1]
    --toc-title <title>        Title above the table of contents [default: Contents]
    --config <path>            Read options from this YAML file instead of
                               ~/.config/markpdf/config.yml
    --print-config             Print the effective configuration as YAML
                               (command line, environment and config file
                               merged) and exit

  If you use "-" as the file argument, markpdf will read from stdin.
  Complete HTML documents (and .html files) are rendered directly,
  skipping the markdown conversion.
  Images are resolved relative to the input file's directory.

  Options can also be set in ~/.config/markpdf/config.yml (keys are the
  long option names, e.g. "page-size: letter"; list-valued keys work for
  repeatable options, e.g. "font: [font1.ttf, font2.ttf]") or through
  MARKPDF_* environment variables (e.g. MARKPDF_STYLE). Command line
  options win over environment variables, which win over the config file.
  The look layers like this: --style picks a whole layout/typography
  stylesheet, --theme recolors it, and --css overrides anything on top.
  DOC

def abort_with(message : String)
  STDERR.puts "markpdf: #{message}"
  exit 1
end

# List the built-in stylesheets, marking the selected one.
def list_styles(selected : String)
  Markd::Pdf.style_names.each do |name|
    suffix = name == selected ? " (current)" : ""
    puts "#{name.ljust(8)} #{Markd::Pdf.style_description(name)}#{suffix}"
  end
end

def setup_emoji_font(emoji_font : String)
  abort_with("emoji font file not found: #{emoji_font}") unless File.file?(emoji_font)
  begin
    Markd::Pdf.emoji_font = emoji_font
  rescue error : Markd::Pdf::Error
    abort_with(error.message.to_s)
  end
end

def register_fonts(font_paths : Array(String))
  font_paths.each do |font_path|
    abort_with("font file not found: #{font_path}") unless File.file?(font_path)
    begin
      Markd::Pdf.register_font(font_path)
    rescue error : Markd::Pdf::Error
      abort_with(error.message.to_s)
    end
  end
end

# Everything the render paths share, so main, build_renderer and
# render_kdp don't each repeat the full parameter list.
private record RenderOptions, markd_options : Markd::Options, style : String,
  theme : String?, code_theme : String?, page_size : String, margins : String,
  kdp : Bool, mirror_headers : Bool, base_dir : String, header : String,
  footer : String, html_input : Bool, pageless : Bool, hyphenate : Bool,
  language : String

def build_renderer(config : RenderOptions)
  Markd::Pdf::Renderer.new(
    options: config.markd_options,
    style: config.style,
    theme: config.theme,
    code_theme: config.code_theme,
    page_size: config.page_size,
    margins: config.margins,
    kdp: config.kdp,
    mirror_headers: config.mirror_headers,
    base_dir: config.base_dir,
    header: config.header,
    footer: config.footer,
    html_input: config.html_input,
    pageless: config.pageless,
    hyphenate: config.hyphenate,
    language: config.language,
  )
rescue error : Markd::Pdf::Error
  abort_with(error.message.to_s)
end

# The kdp gutter sizing, the TOC page numbers and the kdp warnings all
# come from the library's settle loop; the CLI only picks where the
# PDF lands. KDP output goes to a file: only the file-rendering
# convenience reports the KDP range and margin warnings.
def render_kdp(input, output, config : RenderOptions, toc, toc_depth, toc_min_level, toc_title)
  Markd::Pdf.render(input, output, config.markd_options, page_size: config.page_size,
    base_dir: config.base_dir, header: config.header, footer: config.footer,
    theme: config.theme, html_input: config.html_input, style: config.style,
    pageless: config.pageless, hyphenate: config.hyphenate, language: config.language,
    code_theme: config.code_theme, margins: config.margins, kdp: true,
    mirror_headers: config.mirror_headers, toc: toc, toc_depth: toc_depth,
    toc_title: toc_title, toc_min_level: toc_min_level)
end

# Non-kdp TOC renders go through the same settle loop, against the
# renderer main already built (margins are fixed without the gutter
# table, so one instance serves every pass). The PDF comes back as
# bytes; the caller picks file or stdout.
def render_toc_bytes(input, renderer, toc_depth, toc_min_level, toc_title, pageless) : Bytes
  final_bytes = Bytes.new(0)
  Markd::Pdf.settled_pages(true, toc_depth, toc_title, pageless, size_gutter: false,
    toc_min_level: toc_min_level) do |_, desired_toc|
    bytes, pages, headings = renderer.render_to_memory_with_headings(input, desired_toc)
    final_bytes = bytes
    {pages, headings}
  end
  final_bytes
end

record TocLevels, min : Int32, max : Int32

# --toc-depth: a level N lists 1..N, a range N-M only levels N
# through M, inclusive (so 2-2 is level 2 alone); both bounded by
# 1..6, or the run stops here.
def toc_levels_from(spec : String) : TocLevels
  if match = spec.match(/\A(\d+)(?:-(\d+))?\z/)
    low = match[1].to_i
    high = match[2]?.try &.to_i
    min = high ? low : 1
    max = high || low
    return TocLevels.new(min, max) if min.in?(1..6) && max.in?(1..6) && min <= max
  end
  abort_with("--toc-depth needs a level or level range between 1 and 6, like 2 or 2-6 (got '#{spec}')")
end

def load_css_layers(renderer, css_paths : Array(String)) : Nil
  css_paths.each do |css_path|
    abort_with("CSS file not found: #{css_path}") unless File.file?(css_path)
    renderer.add_css(File.read(css_path))
  end
end

def deliver_pdf(input, output : String?, renderer, config : RenderOptions,
                toc : Bool, toc_levels : TocLevels, toc_title : String) : Nil
  if config.kdp
    # KDP keeps the file-rendering path: it is the only one that
    # reports the range and margin warnings.
    target = output || File.tempname("markpdf", ".pdf")
    begin
      render_kdp(input, target, config, toc, toc_levels.max, toc_levels.min, toc_title)
      STDOUT.write(File.read(target).to_slice) unless output
    ensure
      File.delete?(target) unless output
    end
  else
    bytes = toc ? render_toc_bytes(input, renderer, toc_levels.max, toc_levels.min,
      toc_title, config.pageless) : renderer.render_to_memory(input)
    output ? File.write(output, bytes) : STDOUT.write(bytes)
  end
end

def main(source, output, page_size, margin, css_paths, font_paths, emoji_font, header, footer, theme, code_theme, style, html_input, pageless, hyphenate, language, no_remote_images, kdp, mirror_headers, toc, toc_depth_string, toc_title)
  input = Cli.read_source(source)
  base_dir = source == "-" ? "." : File.dirname(File.expand_path(source))

  Markd::Pdf.fetch_remote_images = !no_remote_images

  toc_levels = toc_levels_from(toc_depth_string)

  if kdp && font_paths.empty?
    STDERR.puts "markpdf: warning: no --font given; kdp mode embeds whatever system fonts cover the text. Pass --font to control the embedded typefaces."
  end

  options = Markd::Options.new
  options.gfm = true

  config = RenderOptions.new(
    markd_options: options,
    style: style,
    theme: theme,
    code_theme: Markd::Pdf.pick_code_theme(code_theme, theme, style),
    page_size: page_size,
    margins: margin,
    kdp: kdp,
    mirror_headers: mirror_headers,
    base_dir: base_dir,
    header: header || "",
    footer: footer || "",
    html_input: html_input,
    pageless: pageless,
    hyphenate: hyphenate,
    language: language,
  )
  renderer = build_renderer(config)

  load_css_layers(renderer, css_paths)
  setup_emoji_font(emoji_font) if emoji_font
  register_fonts(font_paths)

  deliver_pdf(input, output, renderer, config, toc, toc_levels, toc_title)
end

argv, config_path = Cli.config_argv("markpdf", ARGV)
options = Docopt.docopt_config(doc, argv: argv,
  config_file_path: config_path, env_prefix: "MARKPDF",
  print_config_option: "--print-config")

if options["--version"]
  puts "Markpdf #{Cli::VERSION}"
  exit 0
end

if options["--list-styles"]
  list_styles(Cli.option_string(options["--style"], "default"))
  exit 0
end

if options["--print-style"]
  # Which stylesheet to print comes from --style; docopt cannot express
  # an optional option argument, so there is no --print-style <style>.
  name = Cli.option_string(options["--style"], "default")
  begin
    puts Markd::Pdf.style_css(name)
  rescue error : Markd::Pdf::Error
    abort_with(error.message.to_s)
  end
  exit 0
end

begin
  file = options["<file>"] || "-"
  main(
    file.as(String),
    Cli.option_string(options["--output"]),
    Cli.option_string(options["--page-size"], "a4"),
    Cli.option_string(options["--margin"], "20"),
    Cli.option_list(options["--css"]?),
    Cli.option_list(options["--font"]?),
    Cli.option_string(options["--emoji-font"]),
    Cli.option_string(options["--header"]),
    Cli.option_string(options["--footer"]),
    Cli.option_string(options["--theme"]),
    Cli.option_string(options["--code-theme"]),
    Cli.option_string(options["--style"], "default"),
    (file.as(String).ends_with?(".html") || file.as(String).ends_with?(".htm")),
    Cli.option_flag(options["--pageless"]),
    Cli.option_flag(options["--hyphenate"]),
    Cli.option_string(options["--language"], "en"),
    Cli.option_flag(options["--no-remote-images"]),
    Cli.option_flag(options["--kdp"]),
    Cli.option_flag(options["--mirror-headers"]),
    Cli.option_flag(options["--toc"]),
    Cli.option_string(options["--toc-depth"], "1"),
    Cli.option_string(options["--toc-title"], "Contents"),
  )
rescue error : Markd::Pdf::Error | Cli::Error | File::Error | IO::Error
  abort_with(error.message.to_s)
end
