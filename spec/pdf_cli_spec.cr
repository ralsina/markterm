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

describe "markpdf CLI" do
  it "renders a file to a PDF" do
    path = File.tempname("markpdf_cli", ".md")
    output_path = File.tempname("markpdf_cli", ".pdf")
    File.write(path, "# CLI Test\n\nbody text")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "-o", output_path])
      status.exit_code.should eq(0), error
      content = File.read(output_path)
      content[0, 5].should eq("%PDF-")
    ensure
      File.delete?(path)
      File.delete?(output_path)
    end
  end

  it "writes the PDF to stdout without -o" do
    status, output, _error = run_cli(BIN_MARKPDF, ["-"], input: "# Stdout Test\n\nbody")
    status.exit_code.should eq(0)
    output[0, 5].should eq("%PDF-")
  end

  it "reports its version" do
    status, output, _error = run_cli(BIN_MARKPDF, ["--version"])
    status.exit_code.should eq(0)
    output.should match(/\AMarkpdf \d+\.\d+\.\d+/)
  end

  it "shows usage on --help" do
    status, output, _error = run_cli(BIN_MARKPDF, ["--help"])
    status.exit_code.should eq(0)
    output.should contain("Usage:")
    output.should contain("--page-size")
  end

  it "fails for an unknown page size" do
    path = File.tempname("markpdf_cli", ".md")
    File.write(path, "content")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "--page-size", "a0", "-o", "/tmp/markpdf_cli_x.pdf"])
      status.exit_code.should eq(1)
      error.should contain("unknown page size")
    ensure
      File.delete?(path)
    end
  end

  it "renders with --hyphenate and rejects an unknown --language" do
    path = File.tempname("markpdf_cli", ".md")
    output_path = File.tempname("markpdf_cli", ".pdf")
    File.write(path, "# Hyphenated\n\ninternationalization internationalization")
    begin
      status, _output, error = run_cli(BIN_MARKPDF,
        [path, "--style", "book", "--hyphenate", "-o", output_path])
      status.exit_code.should eq(0), error
      File.read(output_path)[0, 5].should eq("%PDF-")

      status, _output, error = run_cli(BIN_MARKPDF,
        [path, "--style", "book", "--hyphenate", "--language", "tlh", "-o", output_path])
      status.exit_code.should eq(1)
      error.should contain("tlh")
    ensure
      File.delete?(path)
      File.delete?(output_path)
    end
  end

  it "fails for a missing css file" do
    path = File.tempname("markpdf_cli", ".md")
    File.write(path, "content")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "--css", "/nonexistent.css"])
      status.exit_code.should eq(1)
      error.should contain("CSS file not found")
    ensure
      File.delete?(path)
    end
  end
end
