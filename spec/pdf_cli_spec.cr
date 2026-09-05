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

  it "warns on stderr when an image cannot be loaded" do
    path = File.tempname("markpdf_cli", ".md")
    output_path = File.tempname("markpdf_cli", ".pdf")
    File.write(path, "# Broken image\n\n![missing](no-such-image-XYZ.png)\n")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "-o", output_path])
      status.exit_code.should eq(0), error
      error.should contain("could not load image")
      error.should contain("no-such-image-XYZ.png")
      File.read(output_path)[0, 5].should eq("%PDF-")
    ensure
      File.delete?(path)
      File.delete?(output_path)
    end
  end

  # Pathological inputs must come back as a clean render or a clean
  # error — never a signal exit from the C++ side of the renderer.
  # Running through the CLI makes a segfault visible as a signal.
  describe "pathological inputs" do
    it "errors cleanly on an empty document" do
      status, _output, error = run_cli(BIN_MARKPDF, ["-"], input: "")
      status.normal_exit?.should be_true, "renderer crashed on empty input"
      status.success?.should be_false
      error.should_not be_empty
    end

    it "survives wildly malformed html" do
      garbage = String.build do |io|
        50.times { io << "<p><b><i><table><td><tr>unclosed <div style=" }
      end
      status, _output, _error = run_cli(BIN_MARKPDF, ["-"], input: garbage)
      status.normal_exit?.should be_true, "renderer crashed on malformed html"
    end

    it "survives a complete-html document of garbage" do
      garbage = "<!DOCTYPE html><html><head><title>x</title></head><body>" +
                ("<span style=\"color:#fff\"><table>" * 200) + "tail"
      status, _output, _error = run_cli(BIN_MARKPDF, ["-"], input: garbage)
      status.normal_exit?.should be_true, "renderer crashed on garbage html"
    end

    it "survives deep markdown nesting" do
      status, _output, _error = run_cli(BIN_MARKPDF, ["-"], input: ("> " * 400) + "deep")
      status.normal_exit?.should be_true, "renderer crashed on deep nesting"
    end

    it "survives a long unbreakable string" do
      status, _output, _error = run_cli(BIN_MARKPDF, ["-"], input: ("x" * 100_000) + "\n")
      status.normal_exit?.should be_true, "renderer crashed on a long word"
    end

    it "survives a large pile of random text" do
      status, _output, _error = run_cli(BIN_MARKPDF, ["-"], input: Random::Secure.hex(60_000))
      status.normal_exit?.should be_true, "renderer crashed on random text"
    end
  end
end

it "renders left|center|right header and footer sections" do
  pdftotext = Process.find_executable("pdftotext")
  pending!("pdftotext not available") unless pdftotext
  path = File.tempname("markpdf_cli", ".md")
  output_path = File.tempname("markpdf_cli", ".pdf")
  File.write(path, "# Sectioned\n\nbody")
  begin
    status, _output, error = run_cli(BIN_MARKPDF,
      [path, "-o", output_path, "--header", "HEADL|HEADM|HEADR",
       "--footer", "FOOTL|%p/%t|FOOTR"])
    status.exit_code.should eq(0), error
    text = IO::Memory.new
    Process.run(pdftotext, ["-layout", output_path, "-"], output: text, error: IO::Memory.new)
    lines = text.to_s.lines
    header_lines = lines.select(&.includes?("HEADL"))
    header_lines.size.should eq(1)
    header_lines.first.should contain("HEADM")
    header_lines.first.should contain("HEADR")
    footer_lines = lines.select(&.includes?("FOOTL"))
    footer_lines.size.should eq(1)
    footer_lines.first.should contain("1/1")
    footer_lines.first.should contain("FOOTR")
    lines.join("\n").should_not contain("%p")
  ensure
    File.delete?(path)
    File.delete?(output_path)
  end
end

it "draws headers even without embedded fonts" do
  # base-14-only documents used to silently drop headers/footers
  pdftotext = Process.find_executable("pdftotext")
  pending!("pdftotext not available") unless pdftotext
  path = File.tempname("markpdf_cli", ".md")
  output_path = File.tempname("markpdf_cli", ".pdf")
  File.write(path, "# Plain\n\nbody")
  begin
    status, _output, error = run_cli(BIN_MARKPDF,
      [path, "-o", output_path, "--header", "PLAINHEAD"])
    status.exit_code.should eq(0), error
    text = IO::Memory.new
    Process.run(pdftotext, ["-layout", output_path, "-"], output: text, error: IO::Memory.new)
    text.to_s.should contain("PLAINHEAD")
  ensure
    File.delete?(path)
    File.delete?(output_path)
  end
end
