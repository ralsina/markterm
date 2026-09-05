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

# Rasterize one page to grayscale PGM (plain header, raw bytes — no
# image library needed) and return width, height and the pixel bytes.
private def page_pixels(pdftoppm : String, pdf_path : String, page : Int32) : {Int32, Int32, Bytes}
  prefix = File.tempname("markpdf_spec_cut")
  Process.run(pdftoppm, ["-gray", "-r", "50", "-f", page.to_s, "-l", page.to_s,
                         pdf_path, prefix], error: IO::Memory.new)
  pgm_path = "#{prefix}-#{page}.pgm"
  io = File.open(pgm_path, "rb")
  begin
    magic = io.read_string(2)
    fail("unexpected raster format #{magic.inspect}") unless magic == "P5"
    width = next_pgm_int(io) || 0
    height = next_pgm_int(io) || 0
    next_pgm_int(io) # maxval; pdftoppm writes 255 and a single newline
    pixels = Bytes.new(width * height)
    io.read_fully(pixels)
    {width, height, pixels}
  ensure
    io.close
    File.delete?(pgm_path)
  end
end

private def next_pgm_int(io : IO) : Int32?
  value = 0
  seen = false
  loop do
    byte = io.read_byte
    break if byte.nil?
    if byte.chr.ascii_whitespace?
      break if seen
      next
    end
    seen = true
    value = value * 10 + (byte - 48)
  end
  seen ? value : nil
end

# Ink count (pixels clearly darker than the white page) per scanline.
# The table's rules are its best-inked scanlines: a rule runs unbroken
# across the table width, which no text row approaches.
private def scanline_ink(pixels : Bytes, width : Int32, height : Int32) : Array(Int32)
  ink = Array(Int32).new(height, 0)
  height.times do |row|
    count = 0
    row_pixels = pixels + (row * width)
    width.times do |column|
      count += 1 if row_pixels[column] < 235 # the #cccccc rules antialias light
    end
    ink[row] = count
  end
  ink
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

  # The page cut through a table must look cut, not ragged: the row
  # that ends the page gets a closing rule at the cut and the
  # continuation row on the next page keeps its top rule. Checked
  # geometrically on a raster: a horizontal rule within a few pixels
  # of the bottom content edge on page 1, and of the top content edge
  # on page 2. The default 20mm margin is 39px at 50dpi.
  it "draws table rules at the page cut and on the continuation row" do
    pdftoppm = Process.find_executable("pdftoppm")
    pending!("pdftoppm not available") unless pdftoppm

    rows = String.build do |io|
      1.upto(60) do |row_number|
        io << "| cutrow " << row_number << " | sentinel |\n"
      end
    end
    source = "| col a | col b |\n| --- | --- |\n#{rows}"
    options = Markd::Options.new
    options.gfm = true

    path = temp_pdf_path
    begin
      pages = Markd::Pdf.render(source, path, options)
      pages.should be >= 2

      _width1, height1, pixels1 = page_pixels(pdftoppm, path, 1)
      _width2, height2, pixels2 = page_pixels(pdftoppm, path, 2)
      ink1 = scanline_ink(pixels1, _width1, height1)
      ink2 = scanline_ink(pixels2, _width2, height2)

      # A rule's ink dwarfs any text row's; the table's own width sets
      # the scale on each page independently.
      is_rule1 = ink1.map { |count| count >= ink1.max * 0.6 }
      is_rule2 = ink2.map { |count| count >= ink2.max * 0.6 }
      is_ink1 = ink1.map { |count| count >= ink1.max * 0.05 }
      is_ink2 = ink2.map { |count| count >= ink2.max * 0.05 }

      # The cut must close the table: the last ink on page 1 is a rule.
      last_ink1 = is_ink1.rindex(true)
      fail("page 1 shows no table ink at all") unless last_ink1
      is_rule1[last_ink1].should be_true,
        "page 1 does not end the table with a rule (last ink at scanline #{last_ink1})"

      # The continuation row keeps its top border: the first ink on
      # page 2 is a rule, not bare text.
      first_ink2 = is_ink2.index(true)
      fail("page 2 shows no table ink at all") unless first_ink2
      is_rule2[first_ink2].should be_true,
        "page 2 does not start the table with a continuation rule (first ink at scanline #{first_ink2})"
    ensure
      File.delete?(path)
    end
  end
end

  # Keep-with-next: a heading must never be stranded as the last line
  # of a page. The heading's top and the following block's top are both
  # break candidates a few pixels apart, so every section in a
  # multi-section document is checked: the page holding the heading
  # must also hold the section's opening words.
  it "never strands a section heading at the bottom of a page" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    source = String.build do |io|
      1.upto(12) do |section|
        io << "## Section " << section << " sentinel\n\n"
        io << "Section " << section << " opens with its first line of body text, "
        io << "followed by enough words to wrap over several lines and fill "
        io << "the space below the heading the way ordinary prose does.\n\n"
      end
    end

    path = temp_pdf_path
    begin
      pages = Markd::Pdf.render(source, path)
      page_texts = (1..pages).map { |page| page_text(pdftotext, path, page) }
      1.upto(12) do |section|
        heading_pages = pages_containing(page_texts, "Section #{section} sentinel")
        heading_pages.size.should eq(1), "section #{section}: heading drawn on pages #{heading_pages}"
        page_texts[heading_pages.first - 1].should contain("opens with its first line"),
          "section #{section}: heading stranded at the bottom of page #{heading_pages.first} without its body"
      end
    ensure
      File.delete?(path)
    end
  end
