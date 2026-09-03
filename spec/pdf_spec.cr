require "./spec_helper"

def temp_pdf_path : String
  File.tempname("markpdf_spec", ".pdf")
end

def sample_markdown : String
  <<-MD
    # Sample

    A paragraph with **bold** and *italic* text.

    - One
    - Two
    MD
end

describe Markd::Pdf do
  describe ".document_html" do
    it "wraps the body in a document with the stylesheet" do
      html = Markd::Pdf.document_html("<p>hello</p>")
      html.should contain("<style>")
      html.should contain(Markd::Pdf.css)
      html.should contain("<p>hello</p>")
    end

    it "uses the first heading as the title" do
      html = Markd::Pdf.document_html("<h1>My Title</h1><p>body</p>")
      html.should contain("<title>My Title</title>")
    end

    it "falls back to Untitled without headings" do
      html = Markd::Pdf.document_html("<p>body</p>")
      html.should contain("<title>Untitled</title>")
    end
  end

  describe ".css=" do
    it "appends user css to the default stylesheet" do
      Markd::Pdf.css = "p { color: red; }"
      Markd::Pdf.css.should contain(Markd::Pdf::DEFAULT_CSS)
      Markd::Pdf.css.should contain("p { color: red; }")
    ensure
      Markd::Pdf.reset_css
    end
  end

  describe ".register_font" do
    it "raises for a file that is not a TrueType font" do
      path = File.tempname("markpdf_spec", ".ttf")
      File.write(path, "this is not a font")
      begin
        expect_raises(Markd::Pdf::Error, "TrueType") do
          Markd::Pdf.register_font(path)
        end
      ensure
        File.delete?(path)
      end
    end

    it "accepts a system TTF when one is available" do
      ttf = Dir.glob("/usr/share/fonts/**/*.ttf").first?
      next unless ttf
      Markd::Pdf.register_font(ttf)
    end
  end

  describe ".render" do
    it "renders a short document to a single-page PDF" do
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(sample_markdown, path)
        pages.should eq(1)
        content = File.read(path)
        content.size.should be > 1000
        content[0, 5].should eq("%PDF-")
      ensure
        File.delete?(path)
      end
    end

    it "paginates long documents over multiple pages" do
      paragraph = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor. "
      long_document = String.build do |builder|
        builder << "# Long Document\n\n"
        60.times do |index|
          builder << "Paragraph #{index}: #{paragraph * 8}\n\n"
        end
      end
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(long_document, path)
        pages.should be > 1
      ensure
        File.delete?(path)
      end
    end

    it "renders tables, code blocks and alerts from markdown" do
      source = <<-MD
        | Name | Value |
        |------|-------|
        | a    | 1     |

        ```text
        code block
        ```

        > [!WARNING]
        > Careful.
        MD
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(source, path)
        pages.should eq(1)
        File.size(path).should be > 1000
      ensure
        File.delete?(path)
      end
    end

    it "supports letter page size" do
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(sample_markdown, path, page_size: "letter")
        pages.should eq(1)
        File.exists?(path).should be_true
      ensure
        File.delete?(path)
      end
    end

    it "accepts header and footer templates" do
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(sample_markdown, path, footer: "page %p of %t", header: "Markpdf spec")
        pages.should eq(1)
        File.size(path).should be > 1000
      ensure
        File.delete?(path)
      end
    end

    it "rejects unknown page sizes" do
      path = temp_pdf_path
      begin
        expect_raises(Markd::Pdf::Error, "unknown page size") do
          Markd::Pdf.render(sample_markdown, path, page_size: "a5")
        end
      ensure
        File.delete?(path)
      end
    end

    it "resolves images relative to base_dir" do
      # 1x1 red PNG
      png = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
      image_path = File.tempname("markpdf_spec", ".png")
      File.write(image_path, png, mode: "wb")
      base_dir = File.dirname(image_path)
      source = "![dot](#{File.basename(image_path)})\n"
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(source, path, base_dir: base_dir)
        pages.should eq(1)
      ensure
        File.delete?(image_path)
        File.delete?(path)
      end
    end
  end
end
