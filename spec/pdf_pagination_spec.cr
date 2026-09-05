require "./spec_helper"

# Per-page drawing integrity guards for the paginated PDF renderer.
#
# Pagination bugs (bad clip windows, flow-space mapping, draw-time
# pruning) make content vanish or jump between pages while layout — and
# therefore page counts — stay correct, and litehtml's own suite only
# draws with clips that start at the document top. These examples render
# multi-page documents and check, with pdftotext, that every item is
# drawn exactly where pagination put it: each page shows a contiguous,
# strictly increasing run of items, and nothing is dropped or duplicated.
#
# Table rows are atomic: a row is drawn whole on a single page, label
# cell and body cell together, so page breaks land between rows and
# never inside one.

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

# Numbers of the pages whose extracted text contains the token.
private def pages_containing(page_texts : Array(String), token : String) : Array(Int32)
  pages = Array(Int32).new
  page_texts.each_with_index do |page_text, page_index|
    pages << page_index + 1 if page_text.includes?(token)
  end
  pages
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

  # Two-cell rows with a short label and a tall body: the break must
  # land between rows, so every label and the start of its body end up
  # on the same single page. Zero-padded sentinels so "rowlabel02" is
  # never a prefix hit for "rowlabel2"-style tokens.
  it "draws two-cell table rows whole, never cut by a page break" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    filler = "alpha bravo charlie delta echo foxtrot golf hotel india juliet " \
             "kilo lima mike november oscar papa quebec romeo sierra tango " \
             "uniform victor whiskey xray yankee zulu one two three four five " \
             "six seven eight nine ten eleven twelve thirteen fourteen " \
             "fifteen sixteen seventeen eighteen"
    row_count = 30
    rows = String.build do |io|
      1.upto(row_count) do |row_number|
        label = "rowlabel#{row_number.to_s.rjust(2, '0')}"
        body_head = "rbody#{row_number.to_s.rjust(2, '0')}x"
        io << "<tr><td>" << label << "</td><td>" << body_head << ' ' << filler << "</td></tr>"
      end
    end
    source = <<-HTML
      <table>
        <tbody>#{rows}</tbody>
      </table>
      HTML

    path = temp_pdf_path
    begin
      pages = Markd::Pdf.render(source, path, html_input: true)
      pages.should be >= 2

      page_texts = (1..pages).map { |page| page_text(pdftotext, path, page) }
      1.upto(row_count) do |row_number|
        label = "rowlabel#{row_number.to_s.rjust(2, '0')}"
        body_head = "rbody#{row_number.to_s.rjust(2, '0')}x"
        label_pages = pages_containing(page_texts, label)
        body_pages = pages_containing(page_texts, body_head)
        label_pages.size.should eq(1), "row #{row_number}: label drawn on pages #{label_pages}"
        body_pages.size.should eq(1), "row #{row_number}: body drawn on pages #{body_pages}"
        label_pages.should eq(body_pages), "row #{row_number}: label and body on different pages"
      end
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
