require "./markterm"
require "docopt"
require "markd"

doc = <<-DOC
Markterm - A tool to render markdown to the terminal

Usage:
  markterm <file> [-t <theme>]
  markterm -h | --help
  markterm --version

Options:
  -h --help     Show this screen.
  -t <theme>    Which theme to use
  --version     Show version.
DOC

def main(source)
  puts Markd.to_term(File.read(source))
end

options = Docopt.docopt(doc, ARGV)
if options["--version"]
  puts "Markterm 0.1.0"
  exit 0
end

main(options["<file>"].as(String))
