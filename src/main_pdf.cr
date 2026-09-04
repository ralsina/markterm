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
    --page-size <size>         Page size: a4 or letter [default: a4]
    --margin <margin>          Page margin in millimeters [default: 20]
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
                               wrong for printing

  If you use "-" as the file argument, markpdf will read from stdin.
  Complete HTML documents (and .html files) are rendered directly,
  skipping the markdown conversion.
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

# List the built-in stylesheets, marking the one currently selected.
def list_styles
  Markd::Pdf.style_names.each do |name|
    suffix = name == Markd::Pdf.style ? " (current)" : ""
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

# A dark page with the light default code theme would glow: pick a dark
# code theme for the dark style unless one was asked for explicitly. An
# explicit -t keeps its existing behavior (the code theme follows it
# when tartrazine knows it).
def pick_code_theme(code_theme : String?, theme : String?, style : String)
  return code_theme if code_theme
  return Markd::Pdf::DARK_CODE_THEME if style == "dark" && !theme
  code_theme
end

def main(source, output, page_size, margin, css_paths, font_paths, emoji_font, header, footer, theme, code_theme, style, html_input, pageless)
  input = Cli.read_source(source)
  base_dir = source == "-" ? "." : File.dirname(File.expand_path(source))

  apply_theme(theme) if theme
  css_paths.each do |css_path|
    apply_user_css(css_path)
  end
  setup_emoji_font(emoji_font) if emoji_font
  register_fonts(font_paths)
  code_theme = pick_code_theme(code_theme, theme, style)

  margin_mm = margin.to_f?
  abort_with("invalid margin '#{margin}'") unless margin_mm && margin_mm >= 0

  options = Markd::Options.new
  options.gfm = true

  if output
    Markd::Pdf.render(input, output, options, page_size: page_size, html_input: html_input,
      margin_mm: margin_mm, base_dir: base_dir, header: header || "", footer: footer || "",
      code_theme: code_theme, theme: theme, pageless: pageless)
  else
    # No output file: render to a temporary file and stream to stdout
    temp_path = File.tempname("markpdf", ".pdf")
    begin
      Markd::Pdf.render(input, temp_path, options, page_size: page_size, html_input: html_input,
        margin_mm: margin_mm, base_dir: base_dir, header: header || "", footer: footer || "",
        code_theme: code_theme, theme: theme, pageless: pageless)
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
  list_styles
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
  # Validate --style before any layering: an unknown name aborts here,
  # listing the valid ones.
  style = options["--style"].as(String)
  begin
    Markd::Pdf.style = style
  rescue error : Markd::Pdf::Error
    abort_with(error.message.to_s)
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
    style,
    (file.as(String).ends_with?(".html") || file.as(String).ends_with?(".htm")),
    options["--pageless"] == true,
  )
rescue error
  abort_with(error.message.to_s)
end
