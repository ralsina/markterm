require "./markmark"
require "docopt"
require "markd"

doc = <<-DOC
Markterm - A tool to render markdown to the terminal

Usage:
  markterm <file>
  markterm -h | --help
  markterm --version

Options:
  -h --help                  Show this screen.
  --version                  Show version.

If you use "-" as the file argument, markterm will read from stdin.
DOC

def main(source)
  if source == "-"
    input = STDIN.gets_to_end
  else
    input = File.read(source)
  end
  options = Markd::Options.new
  options.gfm = true
  puts Markd.to_md(input, options)
end

VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}

options = Docopt.docopt(doc, ARGV)
if options["--version"]
  puts "Markterm #{VERSION}"
  exit 0
end

main(
  options["<file>"].as(String),
)
