require "./spec_helper"

# Font fallback and CID embedding guards: CJK text must render through a
# covering font (not tofu boxes) with a clean, warning-free PDF.
#
# The CJK font is the converted Noto Sans CJK in compare/assets/fonts —
# it is not part of the repository, so these examples skip when it (or
# pdftotext) is missing.

private def cjk_font_path : String
  File.expand_path("../compare/assets/fonts/NotoSansCJKsc-Regular.ttf.ttf", __DIR__)
end

private def temp_pdf_path : String
  File.tempname("markpdf_spec", ".pdf")
end

describe "markpdf font fallback" do
  it "renders CJK through a covering font without reader warnings" do
    font_path = cjk_font_path
    pdftotext = Process.find_executable("pdftotext")
    pending!("converted CJK font not available") unless File.file?(font_path)
    pending!("pdftotext not available") unless pdftotext

    source = "Chinese: 中文排版测试 and accents: Señor Cárdenas"
    path = temp_pdf_path
    begin
      Markd::Pdf.register_font(font_path)
      Markd::Pdf.render(source, path, Markd::Options.new)
      text = IO::Memory.new
      stderr = IO::Memory.new
      Process.run(pdftotext, [path, "-"], output: text, error: stderr)
      stderr.to_s.should be_empty, "poppler warnings in the produced PDF"
      text.to_s.should contain("中文排版测试")
      text.to_s.should contain("Señor Cárdenas")
    ensure
      File.delete?(path)
    end
  end

  it "keeps the text layer intact without any registered CJK font" do
    pdftotext = Process.find_executable("pdftotext")
    pending!("pdftotext not available") unless pdftotext

    source = "Chinese: 中文排版测试"
    path = temp_pdf_path
    begin
      Markd::Pdf.render(source, path, Markd::Options.new)
      text = IO::Memory.new
      Process.run(pdftotext, [path, "-"], output: text, error: IO::Memory.new)
      text.to_s.should contain("中文排版测试")
    ensure
      File.delete?(path)
    end
  end
end
