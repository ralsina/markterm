# Code shared by the markterm, markmark and markpdf command line programs
require "docopt-config"

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

  # Default config file path for a tool, e.g. ~/.config/markterm/config.yml
  # (or $XDG_CONFIG_HOME/markterm/config.yml)
  def self.config_path(app_name : String) : String
    config_home = ENV["XDG_CONFIG_HOME"]?
    config_home = File.expand_path("~/.config") if config_home.nil? || config_home.empty?
    File.join(config_home, app_name, "config.yml")
  end

  # docopt-config returns config file values with their YAML types, so an
  # option documented as taking a string can come back as a number (e.g.
  # "margin: 20" as Int32, "margin: 20.5" as Float64, or a numeric docopt
  # default). Normalize those to the String docopt would have produced,
  # ignoring values of other types.
  def self.option_string(value : Docopt::OptionValue?) : String?
    case value
    when String                then value
    when Int32, Int64, Float64 then value.to_s
    end
  end

  # Same, for options that carry a docopt [default: ...] and must not end
  # up nil: fall back to the documented default.
  def self.option_string(value : Docopt::OptionValue?, fallback : String) : String
    option_string(value) || fallback
  end

  # Interpret an option as a boolean flag: true when the flag was given on
  # the command line or set to true in the config file or environment
  # (docopt-config coerces env var values), false or nil otherwise.
  def self.option_flag(value : Docopt::OptionValue?) : Bool
    value == true
  end

  # docopt returns a String when a repeatable option occurs once, and an
  # Array(String) when it repeats (on the command line or through a list
  # in the config file); normalize to an Array(String) either way.
  def self.option_list(value : Docopt::OptionValue?) : Array(String)
    case value
    when Array(String) then value
    when String        then [value]
    else                    [] of String
    end
  end
end
