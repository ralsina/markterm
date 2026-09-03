require "./pdf"
require "./cli"
require "docopt"
require "markd"

doc = <<-DOC
  Markpdf - A tool to render markdown to PDF

  Usage:
    markpdf [<file>] [-o <output>] [-t <theme>] [--page-size <size>] [--margin <margin>] [--css <css>] [--font <font>]... [--emoji-font <font>] [--header <header>] [--footer <footer>]
    markpdf -h | --help
    markpdf --version

  Options:
    -h --help               Show this screen.
    --version               Show version.
    -o <output>             Write the PDF to a file (defaults to standard output)
    -t <theme>              Color theme (a base16/sixteen theme name)
    --page-size <size>      Page size: a4 or letter [default: a4]
    --margin <margin>       Page margin in millimeters [default: 20]
    --css <css>             Additional CSS file with extra styles
    --font <font>           TTF font file to embed (can be repeated). Fonts are
                            matched by their internal family name; system fonts
                            are used automatically when available.
    --emoji-font <font>     TTF font used for emoji and symbols the main fonts
                            lack (auto-detected from system fonts by default)
    --header <header>       Page header text; "%p" is the page number, "%t" the
                            total page count
    --footer <footer>       Page footer text; supports the same placeholders

  If you use "-" as the file argument, markpdf will read from stdin.
  Images are resolved relative to the input file's directory.
  DOC

def abort_with(message : String)
  STDERR.puts "markpdf: #{message}"
  exit 1
end

def apply_theme(theme : String)
  Markd::Pdf.css = Markd::Pdf.css + "\n" + Markd::Pdf.theme_css(theme)
rescue error : Markd::Pdf::Error
  abort_with(error.message.to_s)
end

def apply_user_css(css_path : String)
  abort_with("CSS file not found: #{css_path}") unless File.file?(css_path)
  Markd::Pdf.css = Markd::Pdf.css + "\n" + File.read(css_path)
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

def main(source, output, page_size, margin, css_path, font_paths, emoji_font, header, footer, theme)
  input = Cli.read_source(source)
  base_dir = source == "-" ? "." : File.dirname(File.expand_path(source))

  apply_theme(theme) if theme
  apply_user_css(css_path) if css_path
  setup_emoji_font(emoji_font) if emoji_font
  register_fonts(font_paths)

  margin_mm = margin.to_f?
  abort_with("invalid margin '#{margin}'") unless margin_mm && margin_mm >= 0

  options = Markd::Options.new
  options.gfm = true

  if output
    Markd::Pdf.render(input, output, options, page_size: page_size,
      margin_mm: margin_mm, base_dir: base_dir, header: header || "", footer: footer || "")
  else
    # No output file: render to a temporary file and stream to stdout
    temp_path = File.tempname("markpdf", ".pdf")
    begin
      Markd::Pdf.render(input, temp_path, options, page_size: page_size,
        margin_mm: margin_mm, base_dir: base_dir, header: header || "", footer: footer || "")
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

begin
  file = options["<file>"] || "-"
  fonts = options["--font"] || [] of String
  main(
    file.as(String),
    options["-o"].try &.as(String),
    options["--page-size"].as(String),
    options["--margin"].as(String),
    options["--css"].try &.as(String),
    fonts.as(Array),
    options["--emoji-font"].try &.as(String),
    options["--header"].try &.as(String),
    options["--footer"].try &.as(String),
    options["-t"].try &.as(String),
  )
rescue error
  abort_with(error.message.to_s)
end
