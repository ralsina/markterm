require "spec"
require "colorize"
require "../src/markterm"
require "../src/markmark"

# Enable colorize for tests since output is piped
Colorize.enabled = true

# The CLI specs run the built binaries; build them once if missing
BIN_MARKTERM = File.expand_path("../bin/markterm", __DIR__)
BIN_MARKMARK = File.expand_path("../bin/markmark", __DIR__)

unless File.exists?(BIN_MARKTERM) && File.exists?(BIN_MARKMARK)
  build = Process.run("shards", ["build"], output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  raise "shards build failed, cannot run CLI specs" unless build.success?
end
