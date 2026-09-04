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

  describe ".html_document?" do
    it "detects complete HTML documents" do
      Markd::Pdf.html_document?("<!DOCTYPE html>\n<html><body>x</body></html>").should be_true
      Markd::Pdf.html_document?("  <html><body>x</body></html>").should be_true
      Markd::Pdf.html_document?("# markdown\n\ntext").should be_false
      Markd::Pdf.html_document?("<p>fragment</p>").should be_false
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

  describe ".rewrite_task_lists" do
    it "rewrites a checked task item into a ballot box with check" do
      html = %(<li><input checked="" disabled="" type="checkbox"> done thing</li>)
      Markd::Pdf.rewrite_task_lists(html).should eq(
        %(<li class="task-list-item"><span class="task-box">☑</span> done thing</li>))
    end

    it "rewrites an unchecked task item into an empty ballot box" do
      html = %(<li><input disabled="" type="checkbox"> open thing</li>)
      Markd::Pdf.rewrite_task_lists(html).should eq(
        %(<li class="task-list-item"><span class="task-box">☐</span> open thing</li>))
    end

    it "leaves plain list items untouched" do
      html = "<ul>\n<li>plain item</li>\n</ul>"
      Markd::Pdf.rewrite_task_lists(html).should eq(html)
    end

    it "handles a mixed list with nested plain items" do
      html = "<ul>\n" \
             "<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> done</li>\n" \
             "<li><input disabled=\"\" type=\"checkbox\"> open\n" \
             "<ul>\n<li>nested plain</li>\n</ul>\n</li>\n</ul>"
      rewritten = Markd::Pdf.rewrite_task_lists(html)
      rewritten.should contain(%(<li class="task-list-item"><span class="task-box">☑</span> done</li>))
      rewritten.should contain(%(<li class="task-list-item"><span class="task-box">☐</span> open))
      rewritten.should contain("<li>nested plain</li>")
    end

    it "rewrites the markup markd emits for gfm task lists" do
      markdown = "- [x] done thing\n- [ ] open thing\n"
      options = Markd::Options.new
      options.gfm = true
      html = Markd::Pdf.rewrite_task_lists(Markd.to_html(markdown, options))
      html.should contain(%(<span class="task-box">☑</span> done thing))
      html.should contain(%(<span class="task-box">☐</span> open thing))
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

    it "renders complete HTML documents without markdown processing" do
      # Blank lines and 4-space-indented markup would be mangled by the
      # markdown pipeline; HTML input skips it entirely.
      source = <<-HTML
        <!DOCTYPE html>
        <html>

        <body>

            <div class="section">

                <h2>Indented section</h2>

                <p>Paragraph with 3 * 4 and # not-a-heading.</p>

            </div>

        </body>

        </html>
        HTML
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(source, path, html_input: true)
        pages.should eq(1)
      ensure
        File.delete?(path)
      end
    end

    it "wraps HTML fragments in the document skeleton" do
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render("<p>fragment</p>", path, html_input: true)
        pages.should eq(1)
        File.size(path).should be > 100
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

    it "converts other image formats to PNG" do
      # A tiny 2x2 24-bit BMP
      bmp = IO::Memory.new
      bmp << "BM"
      bmp.write_bytes(74u32)
      bmp.write_bytes(0u16)
      bmp.write_bytes(0u16)
      bmp.write_bytes(54u32)
      bmp.write_bytes(40u32)
      bmp.write_bytes(2i32)
      bmp.write_bytes(2i32)
      bmp.write_bytes(1u16)
      bmp.write_bytes(24u16)
      bmp.write_bytes(0u32)
      bmp.write_bytes(20u32)
      bmp.write_bytes(0i32)
      bmp.write_bytes(0i32)
      2.times { bmp.write(Bytes[10, 100, 200, 0, 200, 100, 10, 0]) }
      image_path = File.tempname("markpdf_spec", ".bmp")
      File.write(image_path, bmp.to_slice, mode: "wb")
      base_dir = File.dirname(image_path)
      source = "![dot](#{File.basename(image_path)})\n"
      path = temp_pdf_path
      begin
        pages = Markd::Pdf.render(source, path, base_dir: base_dir)
        pages.should eq(1)
        File.size(path).should be > 1000
      ensure
        File.delete?(image_path)
        File.delete?(path)
      end
    end
  end
end
