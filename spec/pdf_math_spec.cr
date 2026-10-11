require "./spec_helper"

# End-to-end checks for the MicroTeX vector math path: a document with
# inline and display math renders without errors, the surrounding text
# survives (pdftotext), and the page carries ink where the formulas
# were drawn (the math itself is vector art, invisible to pdftotext).
#
# Skipped when the vector bridge is unavailable (WITH_MICROTEX=0, or
# resources neither found nor embedded) or pdftoppm/pdftotext are
# missing — same gating style as the pagination spec.

private def pdftoppm_path : String?
  Process.find_executable("pdftoppm")
end

private def pdftotext_path : String?
  Process.find_executable("pdftotext")
end

describe "pdf math rendering" do
  it "typesets inline and display math as vector art" do
    pending!("MicroTeX vector math not available") unless MathRender.vector_math?
    rasterizer = pdftoppm_path
    extractor = pdftotext_path
    pending!("pdftoppm not installed") unless rasterizer
    pending!("pdftotext not installed") unless extractor

    source = <<-'MARKDOWN'
      Inline math like $E = mc^2$ sits on the baseline.

      $$\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}$$

      Money like $5 and $10 stays literal.
      MARKDOWN

    path = File.tempname("markpdf_math", ".pdf")
    pages = Markd::Pdf.render(source, path, Markd::Options.new)
    begin
      pages.should be >= 1
      File.size(path).should be > 1000

      # The prose around the formulas survives; the math itself does
      # not appear as text (it is drawn, not spelled).
      text = IO::Memory.new
      Process.run(extractor, [path, "-"], output: text)
      text.to_s.should contain("Inline math like")
      text.to_s.should contain("sits on the baseline")
      text.to_s.should contain("Money like $5 and $10 stays literal")

      # The rendered page carries ink: glyphs were actually drawn.
      prefix = File.tempname("markpdf_math_cut")
      Process.run(rasterizer, ["-gray", "-r", "80", path, prefix], error: IO::Memory.new)
      pgm = File.open("#{prefix}-1.pgm", "rb")
      begin
        pgm.read_string(2).should eq("P5")
        until (byte = pgm.read_byte) == 0x0A
          byte.should_not be_nil
        end
        pixels = Bytes.new(pgm.size - pgm.pos)
        pgm.read_fully(pixels)
        pixels.count { |value| value < 128 }.should be > 1000
      ensure
        pgm.close
        File.delete?("#{prefix}-1.pgm")
      end
    ensure
      File.delete?(path)
    end
  end

  it "keeps rendering when a formula fails to parse" do
    pending!("MicroTeX vector math not available") unless MathRender.vector_math?
    source = "Before\n\n$$\\thisisnotacommand{x}$$\n\nAfter\n"
    path = File.tempname("markpdf_math", ".pdf")
    pages = Markd::Pdf.render(source, path, Markd::Options.new)
    begin
      pages.should be >= 1
      File.size(path).should be > 1000
    ensure
      File.delete?(path)
    end
  end

  it "carries the LaTeX source as ActualText for copy and search" do
    pending!("MicroTeX vector math not available") unless MathRender.vector_math?
    extractor = pdftotext_path
    pending!("pdftotext not installed") unless extractor
    source = "Plain sentence.\n\n$$\\frac{a}{b} + \\sqrt{c}$$\n"
    path = File.tempname("markpdf_math", ".pdf")
    Markd::Pdf.render(source, path, Markd::Options.new)
    begin
      text = IO::Memory.new
      Process.run(extractor, [path, "-"], output: text)
      extracted = text.to_s
      extracted.should contain("Plain sentence.")
      extracted.should contain("\\frac{a}{b}")
      extracted.should contain("\\sqrt{c}")
    ensure
      File.delete?(path)
    end
  end
end
