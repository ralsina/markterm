# Code shared by the markterm and markmark command line programs
module Cli
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}

  # Read the input file, or standard input when the file is "-"
  def self.read_source(source : String) : String
    if source == "-"
      STDIN.gets_to_end
    else
      File.read(source)
    end
  end
end
