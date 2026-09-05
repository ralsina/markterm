require "./spec_helper"

def run_cli(binary : String, args : Array(String), input : String? = nil)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(
    binary,
    args,
    input: IO::Memory.new(input || ""),
    output: stdout,
    error: stderr,
  )
  {status, stdout.to_s, stderr.to_s}
end

describe "markterm CLI" do
  it "renders a file" do
    path = File.tempname("markterm_cli", ".md")
    File.write(path, "# Heading\n\nbody text")
    status, output, _error = run_cli(BIN_MARKTERM, [path])
    File.delete(path)
    status.exit_code.should eq(0)
    output.should contain("Heading")
    output.should contain("body text")
  end

  it "reads from stdin when the file is -" do
    status, output, _error = run_cli(BIN_MARKTERM, ["-"], input: "stdin body")
    status.exit_code.should eq(0)
    output.should contain("stdin body")
  end

  it "reports its version" do
    status, output, _error = run_cli(BIN_MARKTERM, ["--version"])
    status.exit_code.should eq(0)
    output.should match(/\AMarkterm \d+\.\d+\.\d+/)
  end

  it "fails with a friendly error for a missing file" do
    status, _output, error = run_cli(BIN_MARKTERM, ["/nonexistent/file.md"])
    status.exit_code.should_not eq(0)
    error.should contain("markterm:")
    error.should contain("/nonexistent/file.md")
    # A raw Crystal traceback would mention these
    error.should_not contain("from ")
    error.should_not contain("0x")
  end

  it "fails with a friendly error for an unknown theme" do
    path = File.tempname("markterm_cli", ".md")
    File.write(path, "text")
    status, _output, error = run_cli(BIN_MARKTERM, ["-t", "not-a-real-theme", path])
    File.delete(path)
    status.exit_code.should_not eq(0)
    error.should contain("markterm:")
    error.should_not contain("from ")
  end

  it "fails with a friendly error for an invalid width" do
    path = File.tempname("markterm_cli", ".md")
    File.write(path, "text")
    status, _output, error = run_cli(BIN_MARKTERM, ["-w", "abc", path])
    File.delete(path)
    status.exit_code.should_not eq(0)
    error.should contain("invalid width 'abc'")
  end

  it "disables wrapping with -w 0" do
    text = "a word " * 30
    path = File.tempname("markterm_cli", ".md")
    File.write(path, text)
    status, output, _error = run_cli(BIN_MARKTERM, ["-w", "0", path])
    File.delete(path)
    status.exit_code.should eq(0)
    output.strip.split("\n").size.should eq(1)
  end
end

describe "markmark CLI" do
  it "renders a file to markdown" do
    path = File.tempname("markmark_cli", ".md")
    File.write(path, "# Heading\n\nbody with **bold**")
    status, output, _error = run_cli(BIN_MARKMARK, [path])
    File.delete(path)
    status.exit_code.should eq(0)
    output.should contain("# Heading")
    output.should contain("**bold**")
  end

  it "reads from stdin when the file is -" do
    status, output, _error = run_cli(BIN_MARKMARK, ["-"], input: "stdin body")
    status.exit_code.should eq(0)
    output.should contain("stdin body")
  end

  it "reports its own version" do
    status, output, _error = run_cli(BIN_MARKMARK, ["--version"])
    status.exit_code.should eq(0)
    output.should match(/\AMarkmark \d+\.\d+\.\d+/)
  end

  it "fails with a friendly error for a missing file" do
    status, _output, error = run_cli(BIN_MARKMARK, ["/nonexistent/file.md"])
    status.exit_code.should_not eq(0)
    error.should contain("markmark:")
    error.should_not contain("from ")
  end
end

describe "markterm hyphenation CLI" do
  it "rejects an unknown hyphenation language" do
    status, _output, error = run_cli(BIN_MARKTERM, ["-", "--hyphenate", "--language", "tlh"], input: "text")
    status.exit_code.should eq(1)
    error.should contain("hyphenation")
  end

  it "renders with hyphenation enabled" do
    status, output, error = run_cli(BIN_MARKTERM,
      ["-", "-w", "20", "--hyphenate"],
      input: "internationalization internationalization\n")
    status.exit_code.should eq(0), error
    output.should contain("-")
  end
end
