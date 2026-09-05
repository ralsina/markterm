require "./spec_helper"

# Soft-hyphen hyphenation for justified paragraphs: the HTML pass marks
# hyphenation points with &#173;, litehtml treats them as break
# opportunities, and the hyphen is drawn only when a break is taken.

private def temp_pdf_path : String
  File.tempname("markpdf_spec", ".pdf")
end

private def pdf_text(pdftotext : String, pdf_path : String) : String
  output = IO::Memory.new
  # -layout keeps the line structure (and line-end hyphens): default
  # mode reassembles paragraphs and silently joins hyphenated words.
  Process.run(pdftotext, ["-layout", pdf_path, "-"], output: output, error: IO::Memory.new)
  output.to_s
end

describe Markd::Pdf do
  describe ".insert_soft_hyphens" do
    it "marks the hyphenation points of long words" do
      Markd::Pdf.insert_soft_hyphens("<p>hyphenation</p>", "en")
        .should eq("<p>hy&#173;phen&#173;ation</p>")
    end

    it "leaves short and capitalized words alone" do
      Markd::Pdf.insert_soft_hyphens("<p>The cat is Apollo</p>", "en")
        .should eq("<p>The cat is Apollo</p>")
    end

    it "leaves tags and attributes untouched" do
      html = Markd::Pdf.insert_soft_hyphens(
        %(<p><a href="https://example.com/internationalization">internationalization</a></p>), "en")
      html.should contain(%(<a href="https://example.com/internationalization">))
      html.should contain("iza&#173;tion</a>")
    end

    it "leaves code, pre and math spans untouched" do
      html = Markd::Pdf.insert_soft_hyphens(
        %(<pre><code>internationalization</code></pre><p>internationalization</p>), "en")
      html.should contain("<pre><code>internationalization</code></pre>")

      html = Markd::Pdf.insert_soft_hyphens(
        %(<p>before</p><span class="math">a + internationalization</span><p>after</p>), "en")
      html.should contain(%(<span class="math">a + internationalization</span>))
      html.should contain("<p>be&#173;fore</p>")
      html.should contain("<p>af&#173;ter</p>")
    end

    it "keeps entities intact and never hyphenates across them" do
      html = Markd::Pdf.insert_soft_hyphens("<p>internationalization&amp;internationalization</p>", "en")
      html.should contain("&amp;")
      html.should_not contain("&#173;&amp;")
      html.should_not contain("&amp;&#173;")
    end

    it "speaks Spanish when asked to" do
      Markd::Pdf.insert_soft_hyphens("<p>bicicleta</p>", "es")
        .should eq("<p>bi&#173;ci&#173;cle&#173;ta</p>")
    end

    it "raises for languages without embedded patterns" do
      expect_raises(ArgumentError) do
        Markd::Pdf.insert_soft_hyphens("<p>hyphenation</p>", "tlh")
      end
    end
  end
end

describe "hyphenated justified rendering" do
  it "breaks a long word with a hyphen at the line end" do
    pdftotext = Process.find_executable("pdftotext")
    pending!("pdftotext not available") unless pdftotext

    source = <<-MD
      # Justified

      Internationalization internationalization internationalization internationalization
      MD

    path = temp_pdf_path
    begin
      pages = Markd::Pdf.render(source, path, Markd::Options.new, style: "book",
        margin_mm: 45.0, hyphenate: true)
      pages.should be > 0
      text = pdf_text(pdftotext, path)
      # The paragraph is wider than four copies of the word, so a break
      # must have been taken at a soft hyphen.
      text.should contain("-\n")
      # Joining the hyphenated breaks reconstructs every word intact.
      rejoined = text.gsub("-\n", "")
      rejoined.downcase.scan("internationalization").size.should eq(4)
    ensure
      File.delete?(path)
    end
  end

  it "does not hyphenate unless asked to" do
    pdftotext = Process.find_executable("pdftotext")
    pending!("pdftotext not available") unless pdftotext

    source = "Internationalization internationalization internationalization internationalization"

    path = temp_pdf_path
    begin
      Markd::Pdf.render(source, path, Markd::Options.new, style: "book", margin_mm: 30.0)
      # Without soft hyphens in the HTML the layout can only break at
      # spaces, so no line can end in a hyphen.
      pdf_text(pdftotext, path).should_not contain("-\n")
    ensure
      File.delete?(path)
    end
  end
end
