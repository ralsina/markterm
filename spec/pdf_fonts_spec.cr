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

# A system TTF that covers emoji codepoints, searched in the same
# well-known-family order the shim's auto-probe uses. The shim embeds
# TrueType only, so OTF/TTC collections are not candidates.
private def emoji_font_path : String?
  patterns = ["symbola", "notoemoji", "notosanssymbols", "emoji", "symbol"]
  fonts = Dir.glob("/usr/share/fonts/**/*.ttf") +
          Dir.glob("#{Path.home}/.local/share/fonts/**/*.ttf") +
          Dir.glob("#{Path.home}/.fonts/**/*.ttf")
  patterns.each do |pattern|
    fonts.each do |path|
      return path if File.basename(path).downcase.includes?(pattern)
    end
  end
  nil
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

  it "round-trips non-BMP emoji through the alternate-CID path" do
    pdftotext = Process.find_executable("pdftotext")
    font_path = emoji_font_path
    pending!("no emoji/symbol TrueType font available") unless pdftotext && font_path

    # Both are plane-1 codepoints: they cannot ride libharu's 16-bit
    # CID space directly and must come back through the alternate-CID
    # mapping and its ToUnicode entries.
    source = "Emoji: \u{1F600} \u{1F389} plain text"
    path = temp_pdf_path
    begin
      Markd::Pdf.emoji_font = font_path
      Markd::Pdf.render(source, path, Markd::Options.new)
      text = IO::Memory.new
      stderr = IO::Memory.new
      Process.run(pdftotext, [path, "-"], output: text, error: stderr)
      stderr.to_s.should be_empty, "poppler warnings in the produced PDF"
      text.to_s.should contain("\u{1F600}")
      text.to_s.should contain("\u{1F389}")
    ensure
      File.delete?(path)
    end
  end
end
