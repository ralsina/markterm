require "./pdf"
require "./cli"
require "docopt"
require "markd"

doc = <<-DOC
  Markpdf - A tool to render markdown to PDF

  Usage:
    markpdf [<file>] [options]
    markpdf --list-styles
    markpdf -h | --help
    markpdf --version

  Options:
    -h --help                  Show this screen.
    -t <theme>                 Theme to use for coloring output
    --code-theme <code-theme>  Theme to use for coloring code blocks
    --version                  Show version.
    -o <output>                Write the PDF to a file (defaults to standard output)
    --page-size <size>         Page size: a0..a6, b0..b6, letter, legal, or
                               custom WxH in mm (e.g. 100x200) [default: a4]
    --margin <margins>         Page margins in mm, CSS-style: 1 value (all sides),
                               2 (top/bottom, left/right), 4 (top, right, bottom,
                               left) or 5 (... plus gutter) [default: 20]
    --kdp                      KDP print mode: embed every font, drop the
                               outline and scrub metadata
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
    --header <header>          Page header text; "%p" is the page number, "%t" the
                               total page count
    --footer <footer>          Page footer text; supports the same placeholders
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

  If you use "-" as the file argument, markpdf will read from stdin.
  Complete HTML documents (and .html files) are rendered directly,
  skipping the markdown conversion.
  Images are resolved relative to the input file's directory.
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

def main(source, output, page_size, margin, css_paths, font_paths, emoji_font, header, footer, theme, code_theme, style, html_input, pageless, hyphenate, language, no_remote_images, kdp)
  input = Cli.read_source(source)
  base_dir = source == "-" ? "." : File.dirname(File.expand_path(source))

  Markd::Pdf.fetch_remote_images = !no_remote_images

  options = Markd::Options.new
  options.gfm = true

  begin
    renderer = Markd::Pdf::Renderer.new(
      options: options,
      style: style,
      theme: theme,
      code_theme: Markd::Pdf.pick_code_theme(code_theme, theme, style),
      page_size: page_size,
      margins: margin,
      kdp: kdp,
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

  css_paths.each do |css_path|
    abort_with("CSS file not found: #{css_path}") unless File.file?(css_path)
    renderer.add_css(File.read(css_path))
  end
  setup_emoji_font(emoji_font) if emoji_font
  register_fonts(font_paths)

  if output
    renderer.render(input, output)
  else
    # No output file: render to a temporary file and stream to stdout
    temp_path = File.tempname("markpdf", ".pdf")
    begin
      renderer.render(input, temp_path)
      STDOUT.write(File.read(temp_path).to_slice)
    ensure
      File.delete?(temp_path)
    end
  end
end

options = Docopt.docopt(doc, ARGV)

if options["--version"]
  puts "Markpdf #{Cli::VERSION}"
  exit 0
end

if options["--list-styles"]
  list_styles(options["--style"].as(String))
  exit 0
end

if options["--print-style"]
  # Which stylesheet to print comes from --style; docopt cannot express
  # an optional option argument, so there is no --print-style <style>.
  name = options["--style"].as(String)
  begin
    puts Markd::Pdf.style_css(name)
  rescue error : Markd::Pdf::Error
    abort_with(error.message.to_s)
  end
  exit 0
end

begin
  file = options["<file>"] || "-"
  # docopt returns a String when --font occurs once, an Array when it
  # repeats; normalize to an Array(String) either way.
  font_option = options["--font"]?
  fonts = case font_option
          when Array  then font_option.map &.as(String)
          when String then [font_option]
          else             [] of String
          end
  css_option = options["--css"]?
  css_paths = case css_option
              when Array  then css_option.map &.as(String)
              when String then [css_option]
              else             [] of String
              end
  main(
    file.as(String),
    options["-o"].try &.as(String),
    options["--page-size"].as(String),
    options["--margin"].as(String),
    css_paths,
    fonts,
    options["--emoji-font"].try &.as(String),
    options["--header"].try &.as(String),
    options["--footer"].try &.as(String),
    options["-t"].try &.as(String),
    options["--code-theme"].try &.as(String),
    options["--style"].as(String),
    (file.as(String).ends_with?(".html") || file.as(String).ends_with?(".htm")),
    options["--pageless"] == true,
    options["--hyphenate"] == true,
    options["--language"].as(String),
    options["--no-remote-images"] == true,
    options["--kdp"] == true,
  )
rescue error
  abort_with(error.message.to_s)
end
