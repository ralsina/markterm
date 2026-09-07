require "./markmark"
require "./cli"
require "docopt-config"
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

  Options can also be set in ~/.config/markmark/config.yml or through
  MARKMARK_* environment variables. Command line options win over
  environment variables, which win over the config file. Run with
  --print-config to dump the effective configuration as YAML.
  DOC

def main(source)
  input = Cli.read_source(source)
  options = Markd::Options.new
  options.gfm = true
  puts Markd.to_md(input, options)
end

options = Docopt.docopt_config(doc, argv: ARGV,
  config_file_path: Cli.config_path("markmark"), env_prefix: "MARKMARK",
  print_config_option: "--print-config")
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
