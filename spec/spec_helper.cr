require "spec"
require "colorize"
require "../src/markterm"
require "../src/markmark"
require "../src/pdf"

# Enable colorize for tests since output is piped
Colorize.enabled = true

PROJECT_ROOT = File.expand_path("..", __DIR__)

# The PDF target links the C++ shim in ext/; build it if missing
unless File.exists?(File.join(PROJECT_ROOT, "ext", "build", "liblitepdf.a"))
  build = Process.run("make", ["-C", File.join(PROJECT_ROOT, "ext")], output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  raise "make -C ext failed, cannot build liblitepdf" unless build.success?
end

# The CLI specs run the built binaries; build them once if missing
BIN_MARKTERM = File.expand_path("../bin/markterm", __DIR__)
BIN_MARKMARK = File.expand_path("../bin/markmark", __DIR__)
BIN_MARKPDF  = File.expand_path("../bin/markpdf", __DIR__)

unless File.exists?(BIN_MARKTERM) && File.exists?(BIN_MARKMARK) && File.exists?(BIN_MARKPDF)
  build = Process.run("shards", ["build"], output: Process::Redirect::Inherit, error: Process::Redirect::Inherit, chdir: PROJECT_ROOT)
  raise "shards build failed, cannot run CLI specs" unless build.success?
end
