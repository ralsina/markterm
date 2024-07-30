require "markd"
require "./markterm"

def main
  source = File.read(ARGV[0])
  puts Markd.to_term(source)
end

main()