require "./markmark"
require "./cli"
require "docopt"
require "markd"

doc = <<-DOC
  Markmark - A tool to render markdown to markdown

  Usage:
    markmark <file>
    markmark -h | --help
    markmark --version

  Options:
    -h --help                  Show this screen.
    --version                  Show version.

  If you use "-" as the file argument, markmark will read from stdin.
  DOC

def main(source)
  input = Cli.read_source(source)
  options = Markd::Options.new
  options.gfm = true
  puts Markd.to_md(input, options)
end

options = Docopt.docopt(doc, ARGV)
if options["--version"]
  puts "Markmark #{Cli::VERSION}"
  exit 0
end

begin
  main(
    options["<file>"].as(String),
  )
rescue error
  STDERR.puts "markmark: #{error.message}"
  exit 1
end
