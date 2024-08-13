require "./markterm"
require "docopt"
require "markd"

doc = <<-DOC
Markterm - A tool to render markdown to the terminal

Usage:
  markterm <file> [-t <theme>] [--code-theme <code-theme>]
  markterm -h | --help
  markterm --version

Options:
  -h --help                  Show this screen.
  -t <theme>                 Theme to use for coloring output
  --code-theme <code-theme>  Theme to use for coloring code blocks
  --version                  Show version.
DOC

def main(source, theme, code_theme)
  puts Markd.to_term(File.read(source), theme: theme, code_theme: code_theme)
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
  code_theme: options["--code-theme"].try &.as(String))
