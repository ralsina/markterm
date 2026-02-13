require "./markterm"
require "docopt"
require "markd"
require "colorize"

doc = <<-DOC
Markterm - A tool to render markdown to the terminal

Usage:
  markterm <file> [-t <theme>][--code-theme <code-theme>][-l][-c][-w <width>]
  markterm -h | --help
  markterm --version

Options:
  -h --help                  Show this screen.
  -t <theme>                 Theme to use for coloring output
  --code-theme <code-theme>  Theme to use for coloring code blocks
  --version                  Show version.
  -l                         Force html-like links
  -c --color                 Force color output even when piping
  -w <width>                 Maximum line width for text wrapping (0 to disable, auto-detects if not specified)

If you use "-" as the file argument, markterm will read from stdin.
DOC

def main(source, theme, code_theme, force_links = false, force_color = false, width = nil)
  Colorize.enabled = true if force_color

  if source == "-"
    input = STDIN.gets_to_end
  else
    input = File.read(source)
  end
  options = Markd::Options.new
  options.gfm = true

  # Determine max_width: explicit width > auto-detect > nil (no wrapping)
  max_width : Int32? = nil
  if width
    width_int = width.to_i?
    if width_int && width_int >= 0
      max_width = width_int == 0 ? nil : width_int
    end
  elsif STDOUT.tty?
    max_width = Terminal.terminal_width
  end

  puts Markd.to_term(
    input,
    options,
    theme: theme,
    code_theme: code_theme,
    force_links: force_links,
    max_width: max_width,
  )
end

VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}

options = Docopt.docopt(doc, ARGV)

if options["--version"]
  puts "Markterm #{VERSION}"
  exit 0
end

main(
  options["<file>"].as(String),
  theme: options["-t"].try &.as(String),
  code_theme: options["--code-theme"].try &.as(String),
  force_links: options["-l"] != nil,
  force_color: options["--color"] != nil,
  width: options["-w"].try &.as(String),
)
