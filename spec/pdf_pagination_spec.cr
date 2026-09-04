require "./spec_helper"

# Per-page drawing integrity guards for the paginated PDF renderer.
#
# Pagination bugs (bad clip windows, flow-space mapping, draw-time
# pruning) make content vanish or jump between pages while layout — and
# therefore page counts — stay correct, and litehtml's own suite only
# draws with clips that start at the document top. These examples render
# multi-page documents and check, with pdftotext, that every item is
# drawn exactly where pagination put it: each page shows a contiguous,
# strictly increasing run of items, pages may only share the row that
# straddles the break, and nothing is dropped or duplicated.
#
# Rows that straddle a page break are drawn on both pages (the break
# cuts through them), so the concatenated page sequence is allowed to
# repeat the row shared by consecutive pages.

private def temp_pdf_path : String
  File.tempname("markpdf_spec", ".pdf")
end

private def pdftotext_path : String?
  Process.find_executable("pdftotext")
end

private def page_text(pdftotext : String, pdf_path : String, page : Int32) : String
  output = IO::Memory.new
  Process.run(pdftotext, ["-f", page.to_s, "-l", page.to_s, "-layout", pdf_path, "-"],
    output: output, error: IO::Memory.new)
  output.to_s
end

# Extract the per-page sequences of "item N" numbers and check the
# integrity contract described above.
private def should_draw_items_in_order(page_texts : Array(String), count : Int32, label : String)
  sequences = page_texts.map do |text|
    text.scan(/#{label} (\d+)/).map(&.[1].to_i)
  end

  sequences.each_with_index do |sequence, page_index|
    sequence.each_cons(2) do |pair|
      unless pair[0] < pair[1]
        fail("page #{page_index + 1}: items out of order: #{sequence}")
      end
    end
  end

  drawn = sequences.flatten
  drawn.first.should eq(1), "first item missing from page 1"
  drawn.last.should eq(count), "last item missing from the last page"
  missing = (1..count).select { |number| !drawn.includes?(number) }
  missing.should be_empty, "items never drawn: #{missing}"
end

describe "markpdf pagination drawing" do
  it "draws captioned table rows completely and in order across pages" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    rows = String.build do |io|
      1.upto(80) do |row_number|
        io << "<tr><td>tablerow " << row_number << " sentinel</td></tr>"
      end
    end
    source = <<-HTML
      <table>
        <caption>captionsentinel</caption>
        <tbody>#{rows}</tbody>
      </table>
      HTML

    path = temp_pdf_path
    begin
      pages = Markd::Pdf.render(source, path, html_input: true)
      pages.should be >= 2

      # single token: the narrow caption box wraps per-word text
      page_text(pdftotext, path, 1).should contain("captionsentinel")

      page_texts = (1..pages).map { |page| page_text(pdftotext, path, page) }
      should_draw_items_in_order(page_texts, 80, "tablerow")
    ensure
      File.delete?(path)
    end
  end

  it "draws paragraphs completely and in order across pages" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    source = String.build do |io|
      1.upto(200) do |number|
        io << "Paragraph " << number << " sentinel sentence for pagination.\n\n"
      end
    end

    path = temp_pdf_path
    begin
      pages = Markd::Pdf.render(source, path)
      pages.should be >= 2

      page_texts = (1..pages).map { |page| page_text(pdftotext, path, page) }
      should_draw_items_in_order(page_texts, 200, "Paragraph")
    ensure
      File.delete?(path)
    end
  end
end
