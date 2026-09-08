require "./spec_helper"

# The two-pass table of contents.
#
# A TOC's page numbers depend on the layout, and the layout depends on
# the TOC — its own length shifts every page after it — so the numbers
# only exist as a fixed point: render, read the heading map the shim
# collected, rebuild the TOC from it, render again. These specs cover
# the pieces (map parsing, anchor numbering, block building), the map
# the layout produces, and the end-to-end contract: every number the
# TOC shows is the page where that heading actually rendered.

private def temp_pdf_path : String
  File.tempname("markpdf_spec_toc", ".pdf")
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

private def all_page_texts(pdftotext : String, pdf_path : String, pages : Int32) : Array(String)
  (1..pages).map { |page| page_text(pdftotext, pdf_path, page) }
end

# The page whose extracted text contains the token as a standalone
# line (so a TOC entry "Beta" does not match the chapter heading "Beta",
# both of which appear in the document).
private def pages_with_line(page_texts : Array(String), token : String) : Array(Int32)
  pages = [] of Int32
  page_texts.each_with_index do |text, index|
    pages << index + 1 if text.lines.includes?(token)
  end
  pages
end

private def toc_entries
  [
    Markd::Pdf::HeadingEntry.new(1, 1, 2, "Alpha"),
    Markd::Pdf::HeadingEntry.new(2, 2, 2, "Alpha.1"),
    Markd::Pdf::HeadingEntry.new(3, 1, 5, "Beta"),
    Markd::Pdf::HeadingEntry.new(4, 1, 0, "Nowhere"),
  ]
end

describe "Markd::Pdf.parse_heading_map" do
  it "parses index, level, page and title from the shim's map lines" do
    headings = Markd::Pdf.parse_heading_map("1\t1\t3\tAlpha\n2\t2\t4\tBeta  section")
    headings.size.should eq(2)
    headings[0].index.should eq(1)
    headings[0].level.should eq(1)
    headings[0].page.should eq(3)
    headings[0].title.should eq("Alpha")
    headings[1].title.should eq("Beta  section")
  end

  it "strips soft hyphens from titles" do
    headings = Markd::Pdf.parse_heading_map("1\t1\t1\thy\u{00AD}phen\u{00AD}ated")
    headings[0].title.should eq("hyphenated")
  end

  it "returns an empty list for an empty map" do
    Markd::Pdf.parse_heading_map("").should be_empty
  end
end

describe "Markd::Pdf.rewrite_heading_anchors" do
  it "numbers headings in document order and preserves their content" do
    html = "<h1>One</h1><h2>Two</h2><h1>Three</h1>"
    anchored = Markd::Pdf.rewrite_heading_anchors(html)
    anchored.should eq(
      "<h1><a id=\"mtoc-1\"></a>One</h1>" +
      "<h2><a id=\"mtoc-2\"></a>Two</h2>" +
      "<h1><a id=\"mtoc-3\"></a>Three</h1>")
  end

  it "keeps heading text intact, including inline markup and entities" do
    html = "<h1>A <em>bold</em> &amp; long title</h1>"
    anchored = Markd::Pdf.rewrite_heading_anchors(html)
    anchored.should eq("<h1><a id=\"mtoc-1\"></a>A <em>bold</em> &amp; long title</h1>")
  end

  it "does not number headings without visible text, keeping the map aligned" do
    html = "<h1>First</h1><h1>   </h1><h1><span></span></h1><h1>Second</h1>"
    anchored = Markd::Pdf.rewrite_heading_anchors(html)
    anchored.should contain("<h1>   </h1>")
    anchored.should contain("<h1><span></span></h1>")
    anchored.should contain("<a id=\"mtoc-1\"></a>First")
    anchored.should contain("<a id=\"mtoc-2\"></a>Second")
  end
end

describe "Markd::Pdf.toc_html" do
  it "lists entries with links, page numbers and level indents" do
    block = Markd::Pdf.toc_html(toc_entries, 2, "Contents", false).should_not be_nil
    block.should contain("<div class=\"toc-title\">Contents</div>")
    block.should contain("<a href=\"#mtoc-1\"><span class=\"toc-text\">Alpha</span>" +
                         "<span class=\"toc-page\">2</span></a>")
    block.should contain("toc-level-2")
    block.should contain("<a href=\"#mtoc-3\"><span class=\"toc-text\">Beta</span>" +
                         "<span class=\"toc-page\">5</span></a>")
  end

  it "filters by depth and drops headings that fell on no page" do
    block = Markd::Pdf.toc_html(toc_entries, 1, "Contents", false).should_not be_nil
    block.should_not contain("Alpha.1")
    block.should_not contain("Nowhere")
  end

  it "filters by the bottom of a level range" do
    block = Markd::Pdf.toc_html(toc_entries, 2, "Contents", false, min_level: 2).should_not be_nil
    block.should_not contain(">Alpha<") # level 1: below the window
    block.should_not contain(">Beta<")  # level 1: below the window
    block.should contain(">Alpha.1<")   # level 2: inside it
    block.should_not contain("Nowhere") # page 0: still dropped
  end

  it "is nil when every heading falls outside the level range" do
    Markd::Pdf.toc_html(toc_entries, 2, "Contents", false, min_level: 3).should be_nil
  end

  it "omits page numbers in pageless mode" do
    block = Markd::Pdf.toc_html(toc_entries, 2, "Contents", true).should_not be_nil
    block.should contain("Alpha")
    block.should_not contain("toc-page")
  end

  it "escapes the title and entry text" do
    headings = [Markd::Pdf::HeadingEntry.new(1, 1, 1, "A < B & \"C\"")]
    block = Markd::Pdf.toc_html(headings, 1, "T & T", false).should_not be_nil
    block.should contain("T &amp; T")
    block.should contain("A &lt; B &amp; &quot;C&quot;")
  end

  it "is nil when no heading survives the filters" do
    Markd::Pdf.toc_html([] of Markd::Pdf::HeadingEntry, 3, "Contents", false).should be_nil
    only_nowhere = [Markd::Pdf::HeadingEntry.new(1, 1, 0, "Nowhere")]
    Markd::Pdf.toc_html(only_nowhere, 1, "Contents", false).should be_nil
  end
end

describe "Markd::Pdf::Renderer#render_with_headings" do
  renderer = Markd::Pdf::Renderer.new(page_size: "a4")

  it "returns the heading map of a known layout" do
    source = <<-MD
      # First

      #{("word " * 900).strip}

      # Second

      #{("word " * 900).strip}

      # Third
      MD
    pages, headings = renderer.render_with_headings(source, temp_pdf_path)
    pages.should be >= 2
    headings.map(&.title).should eq(["First", "Second", "Third"])
    headings.map(&.level).should eq([1, 1, 1])
    headings.map(&.index).should eq([1, 2, 3])
    headings[0].page.should eq(1)
    headings[2].page.should eq(pages)
  end

  it "renders the TOC block ahead of the body and links entries to anchors" do
    headings = [
      Markd::Pdf::HeadingEntry.new(1, 1, 1, "Solo"),
    ]
    toc = Markd::Pdf.toc_html(headings, 1, "Contents", false)
    pages, mapped = renderer.render_with_headings("# Solo\n\nBody text.", temp_pdf_path, toc)
    pages.should eq(2) # the TOC page, then the body
    mapped.map(&.title).should eq(["Solo"])
    mapped[0].page.should eq(2)
  end
end

describe "markpdf two-pass TOC" do
  it "shows every chapter at the page where it actually rendered" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    chapters = 12
    source = String.build do |io|
      1.upto(chapters) do |chapter|
        io << "# Chaptertoken" << chapter << "\n\n"
        5.times { |run| io << "Filler " << (chapter * 10 + run) << " " << ("prose " * 40).strip << "\n\n" }
      end
    end

    path = temp_pdf_path
    pages = Markd::Pdf.render(source, path, toc: true)
    texts = all_page_texts(pdftotext, path, pages)

    # The TOC page lists each chapter next to the number of the page
    # whose text contains that chapter's heading — and the heading
    # lines appear exactly once each (a TOC entry line carries a page
    # number, so it never equals the bare heading token).
    toc_page = texts.index(&.includes?("Contents")).should_not be_nil
    toc_text = texts[toc_page]
    1.upto(chapters) do |chapter|
      token = "Chaptertoken#{chapter}"
      number = toc_text.scan(/#{token}\s+(\d+)/).first?.try(&.[1])
      number.should_not be_nil, "no TOC entry for #{token}"
      landing = pages_with_line(texts, token)
      landing.size.should eq(1), "#{token} heading appears on pages #{landing}"
      landing[0].to_s.should eq(number), "TOC says #{token} is on page #{number}, it renders on #{landing[0]}"
    end
    File.delete?(path)
  end

  it "lists only the levels in a range, skipping a level-1 document title" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    chapters = 6
    source = String.build do |io|
      io << "# Titletoken\n\n"
      1.upto(chapters) do |chapter|
        io << "## Chaptertoken" << chapter << "\n\n"
        io << "### Sectiontoken" << chapter << "\n\n"
        3.times { |run| io << "Filler " << (chapter * 10 + run) << " " << ("prose " * 40).strip << "\n\n" }
      end
    end

    path = temp_pdf_path
    pages = Markd::Pdf.render(source, path, toc: true, toc_depth: 3, toc_min_level: 2)
    texts = all_page_texts(pdftotext, path, pages)

    toc_page = texts.index(&.includes?("Contents")).should_not be_nil
    toc_text = texts[toc_page]
    # The level-1 title stays out of the TOC...
    toc_text.should_not contain("Titletoken")
    # ...while every level-2 and level-3 heading makes it in with a
    # true number.
    1.upto(chapters) do |chapter|
      ["Chaptertoken", "Sectiontoken"].each do |kind|
        token = "#{kind}#{chapter}"
        number = toc_text.scan(/#{token}\s+(\d+)/).first?.try(&.[1])
        number.should_not be_nil, "no TOC entry for #{token}"
        landing = pages_with_line(texts, token)
        landing.size.should eq(1), "#{token} heading appears on pages #{landing}"
        landing[0].to_s.should eq(number), "TOC says #{token} is on page #{number}, it renders on #{landing[0]}"
      end
    end
    File.delete?(path)
  end

  it "keeps numbers correct in kdp mode, where chapters open on recto pages" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    source = "# One\n\nprose one\n\n# Two\n\nprose two\n\n# Three\n\nprose three\n"
    path = temp_pdf_path
    pages = Markd::Pdf.render(source, path, margins: "20,20,20,20,15", kdp: true, toc: true)
    pages.should be > 3

    texts = all_page_texts(pdftotext, path, pages)
    toc_page = texts.index(&.includes?("Contents")).should_not be_nil
    toc_text = texts[toc_page]

    ["One", "Two", "Three"].each do |chapter|
      number = toc_text.scan(/#{chapter}\s+(\d+)/).first?.try(&.[1])
      number.should_not be_nil, "no TOC entry for #{chapter}"
      landing = pages_with_line(texts, chapter)
      landing.size.should eq(1), "chapter #{chapter} on pages #{landing}"
      landing[0].to_s.should eq(number), "TOC says #{chapter} is on page #{number}, it renders on #{landing[0]}"
      # kdp chapters open on recto (odd) pages, blanks included.
      landing[0].odd?.should be_true
    end
    File.delete?(path)
  end

  it "renders without page numbers in pageless mode" do
    pdftotext = pdftotext_path
    pending!("pdftotext not available") unless pdftotext

    source = "# One\n\nprose one\n\n# Two\n\nprose two\n"
    path = temp_pdf_path
    Markd::Pdf.render(source, path, pageless: true, toc: true)
    text = page_text(pdftotext, path, 1)
    text.should contain("Contents")
    text.should contain("One")
    text.should_not match(/One\s+\d+/)
    File.delete?(path)
  end
end

describe "markpdf CLI --toc" do
  it "renders a TOC and errors on a bad depth" do
    pending!("bin/markpdf not built") unless File.exists?(BIN_MARKPDF)

    source = File.tempname("markpdf_spec_toc", ".md")
    File.write(source, "# Alpha\n\nprose\n\n# Beta\n\nprose\n")
    output = temp_pdf_path
    status = Process.run(BIN_MARKPDF, [source, "--toc", "-o", output],
      error: Process::Redirect::Inherit).success?
    status.should be_true
    File.exists?(output).should be_true

    pdftotext = pdftotext_path
    if pdftotext
      first = page_text(pdftotext, output, 1)
      first.should contain("Contents")
      first.should contain("Alpha")
    end
    File.delete?(output)

    bad = temp_pdf_path
    result = Process.run(BIN_MARKPDF, [source, "--toc", "--toc-depth", "9", "-o", bad],
      output: IO::Memory.new, error: IO::Memory.new)
    result.success?.should be_false
    File.exists?(bad).should be_false
    File.delete?(source)
  end

  it "takes a level range and rejects malformed ones" do
    pending!("bin/markpdf not built") unless File.exists?(BIN_MARKPDF)

    source = File.tempname("markpdf_spec_toc", ".md")
    File.write(source, "# Titletoken\n\nprose\n\n## Alpha\n\nprose\n\n## Beta\n\nprose\n")
    output = temp_pdf_path
    status = Process.run(BIN_MARKPDF, [source, "--toc", "--toc-depth", "2-6", "-o", output],
      error: Process::Redirect::Inherit).success?
    status.should be_true

    pdftotext = pdftotext_path
    if pdftotext
      first = page_text(pdftotext, output, 1)
      first.should contain("Contents")
      first.should contain("Alpha")
      first.should_not contain("Titletoken")
    end
    File.delete?(output)

    ["3-2", "0-2", "2-7", "2-", "soon"].each do |bad_depth|
      bad = temp_pdf_path
      result = Process.run(BIN_MARKPDF, [source, "--toc", "--toc-depth", bad_depth, "-o", bad],
        output: IO::Memory.new, error: IO::Memory.new)
      result.success?.should be_false, "--toc-depth #{bad_depth} should be rejected"
      File.exists?(bad).should be_false
    end
    File.delete?(source)
  end
end
