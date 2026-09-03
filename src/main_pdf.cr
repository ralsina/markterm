require "./pdf"
require "./cli"
require "docopt"
require "markd"

doc = <<-DOC
  Markpdf - A tool to render markdown to PDF

  Usage:
    markpdf [<file>] [-o <output>] [--page-size <size>] [--margin <margin>] [--css <css>] [--font <font>]... [--emoji-font <font>]
    markpdf -h | --help
    markpdf --version

  Options:
    -h --help               Show this screen.
    --version               Show version.
    -o <output>             Write the PDF to a file (defaults to standard output)
    --page-size <size>      Page size: a4 or letter [default: a4]
    --margin <margin>       Page margin in millimeters [default: 20]
    --css <css>             Additional CSS file with extra styles
    --font <font>           TTF font file to embed (can be repeated). Fonts are
                            matched by their internal family name; system fonts
                            are used automatically when available.
    --emoji-font <font>     TTF font used for emoji and symbols the main fonts
                            lack (auto-detected from system fonts by default)

  If you use "-" as the file argument, markpdf will read from stdin.
  Images are resolved relative to the input file's directory.
  DOC

def main(source, output, page_size, margin, css_path, font_paths, emoji_font)
  input = Cli.read_source(source)
  base_dir = source == "-" ? "." : File.dirname(File.expand_path(source))

  if css_path
    unless File.file?(css_path)
      STDERR.puts "markpdf: CSS file not found: #{css_path}"
      exit 1
    end
    Markd::Pdf.css = File.read(css_path)
  end

  if emoji_font
    unless File.file?(emoji_font)
      STDERR.puts "markpdf: emoji font file not found: #{emoji_font}"
      exit 1
    end
    begin
      Markd::Pdf.emoji_font = emoji_font
    rescue error : Markd::Pdf::Error
      STDERR.puts "markpdf: #{error.message}"
      exit 1
    end
  end

  font_paths.each do |font_path|
    unless File.file?(font_path)
      STDERR.puts "markpdf: font file not found: #{font_path}"
      exit 1
    end
    begin
      Markd::Pdf.register_font(font_path)
    rescue error : Markd::Pdf::Error
      STDERR.puts "markpdf: #{error.message}"
      exit 1
    end
  end

  margin_mm = margin.to_f?
  unless margin_mm && margin_mm >= 0
    STDERR.puts "markpdf: invalid margin '#{margin}'"
    exit 1
  end

  options = Markd::Options.new
  options.gfm = true

  if output
    Markd::Pdf.render(input, output, options, page_size: page_size,
      margin_mm: margin_mm, base_dir: base_dir)
  else
    # No output file: render to a temporary file and stream to stdout
    temp_path = File.tempname("markpdf", ".pdf")
    begin
      Markd::Pdf.render(input, temp_path, options, page_size: page_size,
        margin_mm: margin_mm, base_dir: base_dir)
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
  )
rescue error : Markd::Pdf::Error
  STDERR.puts "markpdf: #{error.message}"
  exit 1
rescue error
  STDERR.puts "markpdf: #{error.message}"
  exit 1
end
