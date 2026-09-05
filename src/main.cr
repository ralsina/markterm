require "./markterm"
require "./cli"
require "docopt"
require "markd"
require "colorize"
require "term-color"

doc = <<-DOC
  Markterm - A tool to render markdown to the terminal

  Usage:
    markterm <file> [-t <theme>][--code-theme <code-theme>][-l][-c][-w <width>][--hyphenate][--language <language>][--images|--no-images][--no-links][--no-pager]
    markterm -h | --help
    markterm --version

  Options:
    -h --help                  Show this screen.
    -t <theme>                 Theme to use for coloring output
    --code-theme <code-theme>  Theme to use for coloring code blocks
    --version                  Show version.
    -l                         Force html-like links
    --no-links                 Never emit html-like links
    -c --color                 Force color output even when piping
    -w <width>                 Maximum line width for text wrapping (0 to disable, auto-detects if not specified)
    --hyphenate                Break long words at syllable boundaries when wrapping
    --language <language>      Hyphenation language: en or es [default: en]
    --images                   Force images where the terminal can show them
    --no-images                Never draw images; show placeholders instead
    --no-pager                 Never pipe output to $PAGER

  If you use "-" as the file argument, markterm will read from stdin.
  DOC

# Color: --color wins over everything; otherwise respect the
# terminal's capabilities. NO_COLOR, TERM=dumb and friends mean plain
# text, which the renderer renders with ATX heading hashes.
private def configure_color(force_color : Bool)
  if force_color
    Colorize.enabled = true
  else
    support = Term::Color::Support.new(ENV.to_h)
    Colorize.enabled = support.support? && !support.disabled?
  end
end

# The pager to use for this document, when output is interactive, the
# user has one, and the document is taller than the screen. Interactive
# reading of tall documents goes through the pager; short documents
# and pipes print directly.
private def pager_for(output_string : String) : String?
  return unless STDOUT.tty?
  pager = ENV["PAGER"]?
  return if pager.nil? || pager.empty?
  return unless output_string.lines.size > (Term::Screen.height || 24)
  pager
end

def main(source, theme, code_theme, force_links = false, force_color = false, width = nil,
         hyphenate = false, language = "en", images = nil, no_links = false, no_pager = false)
  configure_color(force_color)

  input = Cli.read_source(source)
  options = Markd::Options.new
  options.gfm = true

  # Determine max_width: explicit width > auto-detect > nil (no wrapping)
  max_width : Int32? = nil
  if width
    width_int = width.to_i?
    if width_int && width_int >= 0
      max_width = width_int == 0 ? nil : width_int
    else
      abort "markterm: invalid width '#{width}'"
    end
  elsif STDOUT.tty?
    max_width = Terminal.terminal_width
  end

  # Validate the language even when no wrapping will happen: a typo in
  # --language should fail loudly, not silently do nothing
  Hyphen::Dictionary.load(language) if hyphenate

  output_string = Markd.to_term(
    input,
    options,
    theme: theme,
    code_theme: code_theme,
    force_links: force_links,
    max_width: max_width,
    hyphenate: hyphenate,
    language: language,
    images: images,
    no_links: no_links,
  )

  pager = no_pager ? nil : pager_for(output_string)
  if pager
    pipe_to_pager(output_string, pager)
  else
    puts output_string
  end
end

# Send rendered text through the user's pager. The pager owns the
# terminal: it inherits stdout and stderr and reads the text on stdin.
private def pipe_to_pager(text : String, pager : String)
  process = Process.new(pager, shell: true, input: Process::Redirect::Pipe,
    output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  begin
    process.input << text
    process.input.close
  rescue IO::Error
    # The pager quit early (the user exited): nothing left to write
  ensure
    process.wait
  end
end

options = Docopt.docopt(doc, ARGV)

if options["--version"]
  puts "Markterm #{Cli::VERSION}"
  exit 0
end

begin
  # --images and --no-images are mutually exclusive alternatives, so
  # exactly one can be set: nil means auto-detect.
  images = if options["--images"] == true
             true
           elsif options["--no-images"] == true
             false
           end
  main(
    options["<file>"].as(String),
    theme: options["-t"].try &.as(String),
    code_theme: options["--code-theme"].try &.as(String),
    force_links: options["-l"] != nil,
    force_color: options["--color"] != nil,
    width: options["-w"].try &.as(String),
    hyphenate: options["--hyphenate"] != nil,
    language: options["--language"].try &.as(String) || "en",
    images: images,
    no_links: options["--no-links"] != nil,
    no_pager: options["--no-pager"] != nil,
  )
rescue error
  STDERR.puts "markterm: #{error.message}"
  exit 1
end
