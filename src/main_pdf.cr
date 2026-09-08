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
                               custom WxH — values under 12 are inches
                               (6x9 = 152.4x228.6mm) [default: a4]
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
    --toc-depth <depth>        Deepest heading level the TOC lists, from
                               1 (chapters only) to 6 [default: 1]
    --toc-title <title>        Title above the table of contents [default: Contents]
    --config <path>            Read options from this YAML file instead of
                               ~/.config/markpdf/config.yml

  If you use "-" as the file argument, markpdf will read from stdin.
  Complete HTML documents (and .html files) are rendered directly,
  skipping the markdown conversion.
  Images are resolved relative to the input file's directory.

  Options can also be set in ~/.config/markpdf/config.yml (keys are the
  long option names, e.g. "page-size: letter"; list-valued keys work for
  repeatable options, e.g. "font: [font1.ttf, font2.ttf]") or through
  MARKPDF_* environment variables (e.g. MARKPDF_STYLE). Command line
  options win over environment variables, which win over the config file.
  Run with --print-config to dump the effective configuration as YAML.
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

def build_renderer(options, style, theme, code_theme, page_size, margins, kdp, mirror_headers, base_dir, header, footer, html_input, pageless, hyphenate, language)
  Markd::Pdf::Renderer.new(
    options: options,
    style: style,
    theme: theme,
    code_theme: Markd::Pdf.pick_code_theme(code_theme, theme, style),
    page_size: page_size,
    margins: margins,
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
rescue error : Markd::Pdf::Error
  abort_with(error.message.to_s)
end

# The kdp gutter sizing, the TOC page numbers and the kdp warnings all
# come from the library's settle loop; the CLI only picks where the
# PDF lands and which code theme applies.
def render_kdp(input, output, margin, options, style, theme, code_theme, page_size, mirror_headers, base_dir, header, footer, html_input, pageless, hyphenate, language, toc, toc_depth, toc_title)
  Markd::Pdf.render(input, output, options, page_size: page_size, base_dir: base_dir,
    header: header || "", footer: footer || "", theme: theme, html_input: html_input, style: style,
    pageless: pageless, hyphenate: hyphenate, language: language,
    code_theme: Markd::Pdf.pick_code_theme(code_theme, theme, style),
    margins: margin, kdp: true, mirror_headers: mirror_headers,
    toc: toc, toc_depth: toc_depth, toc_title: toc_title)
end

# Non-kdp TOC renders go through the same settle loop, against the
# renderer the CLI already built (margins are fixed without the gutter
# table, so one instance serves every pass).
def render_toc(input, output, renderer, toc_depth, toc_title, pageless)
  Markd::Pdf.settled_pages(true, toc_depth, toc_title, pageless, size_gutter: false) do |_, desired_toc|
    renderer.render_with_headings(input, output, desired_toc)
  end
end

# --toc-depth: an integer between 1 and 6, or the run stops here.
def toc_depth_from(depth_string : String) : Int32
  depth = depth_string.to_i?
  return depth if depth && depth.in?(1..6)
  abort_with("--toc-depth needs an integer between 1 and 6 (got '#{depth_string}')")
end

def main(source, output, page_size, margin, css_paths, font_paths, emoji_font, header, footer, theme, code_theme, style, html_input, pageless, hyphenate, language, no_remote_images, kdp, mirror_headers, toc, toc_depth_string, toc_title)
  input = Cli.read_source(source)
  base_dir = source == "-" ? "." : File.dirname(File.expand_path(source))

  Markd::Pdf.fetch_remote_images = !no_remote_images

  toc_depth = toc_depth_from(toc_depth_string)

  if kdp && font_paths.empty?
    STDERR.puts "markpdf: warning: no --font given; kdp mode embeds whatever system fonts cover the text. Pass --font to control the embedded typefaces."
  end

  options = Markd::Options.new
  options.gfm = true

  renderer = build_renderer(options, style, theme, code_theme, page_size, margin, kdp,
    mirror_headers, base_dir, header, footer, html_input, pageless, hyphenate, language)

  css_bodies = [] of String
  css_paths.each do |css_path|
    abort_with("CSS file not found: #{css_path}") unless File.file?(css_path)
    css_bodies << File.read(css_path)
  end
  css_bodies.each do |css_body|
    renderer.add_css(css_body)
  end
  setup_emoji_font(emoji_font) if emoji_font
  register_fonts(font_paths)

  # No output file: render to a temporary file and stream to stdout.
  target = output || File.tempname("markpdf", ".pdf")
  begin
    if kdp
      render_kdp(input, target, margin, options, style, theme, code_theme, page_size,
        mirror_headers, base_dir, header, footer, html_input, pageless, hyphenate,
        language, toc, toc_depth, toc_title)
    elsif toc
      render_toc(input, target, renderer, toc_depth, toc_title, pageless)
    else
      renderer.render(input, target)
    end
    unless output
      STDOUT.write(File.read(target).to_slice)
    end
  ensure
    File.delete?(target) unless output
  end
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
rescue error
  abort_with(error.message.to_s)
end
