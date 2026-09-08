require "./spec_helper"

# zlib stream with stored (uncompressed) deflate blocks: PNG requires
# a zlib wrapper around its image data, and the spec avoids depending
# on any compression library.
private def zlib_stored(data : Bytes) : Bytes
  io = IO::Memory.new
  io.write_bytes(0x78_u8, IO::ByteFormat::BigEndian)
  io.write_byte(0x01_u8) # CMF/FLG: fastest, no dictionary
  offset = 0
  while offset < data.size
    chunk = Math.min(65535, data.size - offset)
    final = offset + chunk == data.size
    io.write_byte(final ? 1_u8 : 0_u8)
    io.write_bytes(chunk.to_u16, IO::ByteFormat::LittleEndian)
    io.write_bytes((~chunk.to_u16), IO::ByteFormat::LittleEndian)
    io.write(data[offset, chunk])
    offset += chunk
  end
  a = 1_u32
  b = 0_u32
  data.each do |byte|
    a = (a + byte) % 65521
    b = (b + a) % 65521
  end
  io.write_bytes(((b << 16) | a).to_u32, IO::ByteFormat::BigEndian)
  io.to_slice
end

# A minimal valid RGB PNG written by hand (zlib + CRC32), so specs can
# control exact pixel dimensions without binary fixtures.
private def write_png_chunk(io : IO, type : String, data : Bytes) : Nil
  io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(type.to_slice)
  io.write(data)
  crc = Digest::CRC32.new
  crc.update(type.to_slice)
  crc.update(data)
  crc_bytes = crc.final
  crc_value = IO::ByteFormat::BigEndian.decode(UInt32, crc_bytes)
  io.write_bytes(crc_value.to_u32, IO::ByteFormat::BigEndian)
end

private def make_png(path : String, width : Int32, height : Int32) : Nil
  io = File.open(path, "wb")
  begin
    io.write(Bytes[137, 80, 78, 71, 13, 10, 26, 10])
    ihdr = IO::Memory.new
    ihdr.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write_byte(8_u8) # bit depth
    ihdr.write_byte(2_u8) # color type: truecolor
    ihdr.write_byte(0_u8) # compression
    ihdr.write_byte(0_u8) # filter
    ihdr.write_byte(0_u8) # interlace
    write_png_chunk(io, "IHDR", ihdr.to_slice)
    raw = IO::Memory.new
    height.times do
      raw.write_byte(0_u8)
      width.times { raw.write(Bytes[200, 30, 30]) }
    end
    idat = zlib_stored(raw.to_slice)
    write_png_chunk(io, "IDAT", idat)
    write_png_chunk(io, "IEND", Bytes.empty)
  ensure
    io.close
  end
end

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

  it "warns when kdp mode runs without explicit fonts" do
    path = File.tempname("markpdf_cli", ".md")
    File.write(path, "content")
    font = Dir.glob("/usr/share/fonts/**/*.ttf").first?
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "--kdp", "-o", "/tmp/markpdf_cli_kdp.pdf"])
      status.exit_code.should eq(0)
      error.should contain("no --font given")

      next unless font # no fonts installed: the quiet case is covered by the warning test
      _status, _output, error = run_cli(BIN_MARKPDF, [path, "--kdp", "--font", font, "-o", "/tmp/markpdf_cli_kdp2.pdf"])
      error.should_not contain("no --font given")
    ensure
      File.delete?(path)
      File.delete?("/tmp/markpdf_cli_kdp.pdf")
      File.delete?("/tmp/markpdf_cli_kdp2.pdf")
    end
  end

  it "warns when a raster image renders below 300 DPI" do
    tiny = File.tempname("markpdf_spec", ".png")
    make_png(tiny, 20, 20)
    md = File.tempname("markpdf_cli", ".md")
    File.write(md, "![tiny](#{tiny})")
    pdf = File.tempname("markpdf_cli", ".pdf")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [md, "--page-size", "6x9", "--kdp", "-o", pdf])
      status.exit_code.should eq(0)
      error.should contain("300 DPI")
    ensure
      File.delete?(tiny)
      File.delete?(md)
      File.delete?(pdf)
    end
  end

  it "warns when kdp margins fall below the no-bleed minimum" do
    path = File.tempname("markpdf_cli", ".md")
    File.write(path, "content")
    pdf = File.tempname("markpdf_cli", ".pdf")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "--kdp", "--margin", "5", "-o", pdf])
      status.exit_code.should eq(0)
      error.should contain("6.35mm")
    ensure
      File.delete?(path)
      File.delete?(pdf)
    end
  end

  it "stays quiet for high-resolution images" do
    big = File.tempname("markpdf_spec", ".png")
    make_png(big, 1200, 1200)
    md = File.tempname("markpdf_cli2", ".md")
    File.write(md, "![big](#{big})")
    pdf = File.tempname("markpdf_cli2", ".pdf")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [md, "--page-size", "6x9", "-o", pdf])
      status.exit_code.should eq(0)
      error.should_not contain("300 DPI")
    ensure
      File.delete?(big)
      File.delete?(md)
      File.delete?(pdf)
    end
  end

  it "fails for an unknown page size" do
    path = File.tempname("markpdf_cli", ".md")
    File.write(path, "content")
    begin
      status, _output, error = run_cli(BIN_MARKPDF, [path, "--page-size", "bogus", "-o", "/tmp/markpdf_cli_x.pdf"])
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
