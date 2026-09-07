require "./spec_helper"
require "http/client"
require "../src/web"

def web_form(body : String) : HTTP::Params
  HTTP::Params.parse(body)
end

def web_params(body : String) : MarkpdfWeb::RenderParams
  MarkpdfWeb::RenderParams.from_form(web_form(body))
end

# A real HTTP server running kemal's middleware stack on an ephemeral
# port: the route specs exercise the full request path, halt included.
WEB_CLIENT = begin
  Kemal.config.env = "test"
  Kemal.config.setup
  web_server = HTTP::Server.new(Kemal.config.handlers)
  web_address = web_server.bind_tcp("127.0.0.1", 0)
  spawn { web_server.listen }
  HTTP::Client.new(web_address.address, web_address.port)
end

describe MarkpdfWeb::RenderParams do
  it "falls back to the CLI defaults for every knob" do
    render_params = web_params("markdown=hello")
    render_params.markdown.should eq("hello")
    render_params.style.should eq("default")
    render_params.theme.should be_nil
    render_params.code_theme.should be_nil
    render_params.page_size.should eq("a4")
    render_params.margins.should eq("20")
    render_params.header.should eq("")
    render_params.footer.should eq("")
    render_params.pageless?.should be_false
    render_params.hyphenate?.should be_false
    render_params.language.should eq("en")
    render_params.custom_css.should be_nil
  end

  it "reads every knob from the form" do
    render_params = web_params("markdown=hello&style=book&theme=gruvbox-material-dark-medium&code_theme=monokai" \
                               "&page_size=letter&margin=5.5&header=Page %p&footer=the end" \
                               "&pageless=true&hyphenate=on&language=es&custom_css=h1 %7B color: red %7D")
    render_params.style.should eq("book")
    render_params.theme.should eq("gruvbox-material-dark-medium")
    render_params.code_theme.should eq("monokai")
    render_params.page_size.should eq("letter")
    render_params.margins.should eq("5.5")
    render_params.header.should eq("Page %p")
    render_params.footer.should eq("the end")
    render_params.pageless?.should be_true
    render_params.hyphenate?.should be_true
    render_params.language.should eq("es")
    render_params.custom_css.should eq("h1 { color: red }")
  end

  it "requires a markdown field" do
    expect_raises(MarkpdfWeb::ParamError, "markdown") do
      web_params("style=book")
    end
  end

  it "rejects documents over the size limit" do
    huge = "x" * (MarkpdfWeb::MAX_MARKDOWN_BYTES + 1)
    expect_raises(MarkpdfWeb::ParamError, "too large") do
      web_params("markdown=#{huge}")
    end
  end

  it "rejects unknown styles, page sizes and languages" do
    expect_raises(MarkpdfWeb::ParamError, "style") do
      web_params("markdown=x&style=gothic")
    end
    expect_raises(MarkpdfWeb::ParamError, "page size") do
      web_params("markdown=x&page_size=bogus")
    end
    expect_raises(MarkpdfWeb::ParamError, "language") do
      web_params("markdown=x&language=fr")
    end
  end

  it "rejects non-numeric and wrong-count margin specs" do
    expect_raises(MarkpdfWeb::ParamError, "margin") do
      web_params("markdown=x&margin=wide")
    end
    expect_raises(MarkpdfWeb::ParamError, "margins") do
      web_params("markdown=x&margin=20,15,30")
    end
  end

  it "accepts large single margins (the engine falls back when sides overflow)" do
    web_params("markdown=x&margin=101").margins.should eq("101")
  end

  it "trims whitespace and caps long header/footer text" do
    render_params = web_params("markdown=x&header=%20%20page %p%20&footer=#{("f" * 1000)}")
    render_params.header.should eq("page %p")
    render_params.footer.size.should eq(MarkpdfWeb::MAX_TEXT_FIELD_CHARS)
  end
end

describe MarkpdfWeb do
  it "renders markdown to PDF bytes" do
    pdf_bytes = MarkpdfWeb.render_to_bytes(web_params("markdown=%23 Hello%0A%0AWorld"))
    String.new(pdf_bytes).should start_with("%PDF")
  end

  it "renders with every knob set" do
    body = "markdown=%23 Titled%0A%0A%60%60%60crystal%0Aputs 1%0A%60%60%60" \
           "&style=book&theme=gruvbox-material-dark-medium&page_size=letter&margin=10" \
           "&header=Page %p of %t&pageless=true&hyphenate=true&language=en" \
           "&custom_css=p %7B color: teal %7D"
    pdf_bytes = MarkpdfWeb.render_to_bytes(web_params(body))
    String.new(pdf_bytes).should start_with("%PDF")
  end

  it "surfaces theme and style errors as Markd::Pdf::Error" do
    expect_raises(Markd::Pdf::Error) do
      MarkpdfWeb.render_to_bytes(web_params("markdown=x&theme=no-such-base16-theme"))
    end
  end

  it "lists the base16 page themes" do
    page_themes = MarkpdfWeb.page_themes
    page_themes.should_not be_empty
    page_themes.should eq(page_themes.sort)
    page_themes.should contain("dracula")
  end
end

describe MarkpdfWeb::LandingPage do
  landing_html = MarkpdfWeb::LandingPage.new.to_s

  it "renders the marketing page with the playground" do
    landing_html.should contain("Playground")
    landing_html.should contain("markpdf")
    landing_html.should contain(%(id="markdown"))
    landing_html.should contain(%(id="preview"))
  end

  it "offers every built-in style" do
    Markd::Pdf.style_names.each do |name|
      landing_html.should contain(%(value="#{name}"))
    end
  end

  it "embeds the sample documents as raw JSON, not HTML-escaped" do
    landing_html.should contain("Feature tour")
    landing_html.should contain(%(const SAMPLES = [{))
  end
end

describe Markd::Pdf do
  it "picks a dark code theme for the dark style unless asked explicitly" do
    Markd::Pdf.pick_code_theme(nil, nil, "dark").should eq(Markd::Pdf::DARK_CODE_THEME)
    Markd::Pdf.pick_code_theme(nil, nil, "book").should be_nil
    Markd::Pdf.pick_code_theme("monokai", nil, "book").should eq("monokai")
    # An explicit page theme keeps the code theme following it.
    Markd::Pdf.pick_code_theme(nil, "gruvbox-material-dark-medium", "dark").should be_nil
  end
end

describe "Markd::Pdf.parse_page_size" do
  it "resolves named sizes case-insensitively" do
    Markd::Pdf.parse_page_size("a4").should eq({210.0, 297.0})
    Markd::Pdf.parse_page_size("A3").should eq({297.0, 420.0})
    Markd::Pdf.parse_page_size("Letter").should eq({215.9, 279.4})
  end

  it "parses custom WxH sizes in millimeters" do
    Markd::Pdf.parse_page_size("100x200").should eq({100.0, 200.0})
    Markd::Pdf.parse_page_size("210.5x297").should eq({210.5, 297.0})
  end

  it "rejects garbage and out-of-range sizes" do
    expect_raises(Markd::Pdf::Error, "unknown page size") do
      Markd::Pdf.parse_page_size("bogus")
    end
    expect_raises(Markd::Pdf::Error, "out of range") do
      Markd::Pdf.parse_page_size("5x5")
    end
    expect_raises(Markd::Pdf::Error, "out of range") do
      Markd::Pdf.parse_page_size("9999x100")
    end
  end
end

describe "Markd::Pdf page sizes end to end" do
  it "renders named and custom sizes at the right dimensions" do
    pdfinfo = Process.find_executable("pdfinfo")
    pending!("pdfinfo not available") unless pdfinfo
    {
      {"a5", "419.528 x 595.276 pts"},
      {"100x200", "283.465 x 566.929 pts"},
    }.each do |page_size, expected|
      pdf = Markd::Pdf.render_to_memory("hi", page_size: page_size)
      path = File.tempname("markpdf-spec", ".pdf")
      begin
        File.write(path, pdf)
        output = IO::Memory.new
        Process.run(pdfinfo, [path], output: output, error: IO::Memory.new)
        output.to_s.should contain(expected)
      ensure
        File.delete?(path)
      end
    end
  end
end

describe "Markd::Pdf image fetch guard" do
  it "skips remote images entirely when fetching is disabled" do
    Markd::Pdf.fetch_remote_images = false
    html = %(<img src="http://example.invalid/x.png" alt="x">)
    begin
      Markd::Pdf.process_images(html, ".", Dir.tempdir, [] of String).should eq(html)
    ensure
      Markd::Pdf.fetch_remote_images = true
    end
  end

  it "refuses non-public and non-http targets" do
    Markd::Pdf.image_fetch_allowed?("http://127.0.0.1/secret.png").should be_false
    Markd::Pdf.image_fetch_allowed?("http://169.254.169.254/latest/meta-data").should be_false
    Markd::Pdf.image_fetch_allowed?("http://192.168.1.10/router.png").should be_false
    Markd::Pdf.image_fetch_allowed?("http://10.0.0.5/internal.png").should be_false
    Markd::Pdf.image_fetch_allowed?("http://[::1]/secret.png").should be_false
    Markd::Pdf.image_fetch_allowed?("file:///etc/passwd").should be_false
    Markd::Pdf.image_fetch_allowed?("ftp://example.com/x.png").should be_false
  end

  it "accepts public literal-IP targets without touching the network" do
    Markd::Pdf.image_fetch_allowed?("https://93.184.216.34/photo.jpg").should be_true
  end

  it "classifies unsafe IPv6 forms" do
    Markd::Pdf.unsafe_ip?("::1").should be_true
    Markd::Pdf.unsafe_ip?("::").should be_true
    Markd::Pdf.unsafe_ip?("fe80::1").should be_true
    Markd::Pdf.unsafe_ip?("fc00::1").should be_true
    Markd::Pdf.unsafe_ip?("::ffff:192.168.1.1").should be_true
    Markd::Pdf.unsafe_ip?("2606:4700::1111").should be_false
  end
end

describe "MarkpdfWeb::RateLimiter" do
  it "allows the budget per window, then refuses until it resets" do
    limiter = MarkpdfWeb::RateLimiter.new(2, 50.milliseconds)
    limiter.allow?("a").should be_true
    limiter.allow?("a").should be_true
    limiter.allow?("a").should be_false
    sleep 80.milliseconds
    limiter.allow?("a").should be_true
  end

  it "tracks keys independently and reports the retry delay" do
    limiter = MarkpdfWeb::RateLimiter.new(1, 500.milliseconds)
    limiter.allow?("x").should be_true
    limiter.allow?("y").should be_true
    limiter.allow?("x").should be_false
    limiter.retry_after("x").should be > 0
    limiter.retry_after("y").should be > 0
  end
end

describe "markpdf-web routes" do
  it "serves the landing page" do
    response = WEB_CLIENT.get("/")
    response.status_code.should eq(200)
    response.headers["Content-Type"].should contain("text/html")
    response.body.should contain("Playground")
  end

  it "renders PDFs from the form" do
    response = WEB_CLIENT.post("/render", body: "markdown=%23 Hello%0A%0AWorld",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    response.status_code.should eq(200)
    response.headers["Content-Type"].should contain("application/pdf")
    response.body.should start_with("%PDF")
    render_seconds = response.headers["X-Render-Time"].to_f
    render_seconds.should be >= 0.0
  end

  it "answers 422 with an explanation for bad knobs" do
    response = WEB_CLIENT.post("/render", body: "markdown=hello&margin=wild",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    response.status_code.should eq(422)
    response.body.should contain("margin")
  end

  it "accepts ISO names and custom WxH page sizes, refusing bad ones" do
    ok = WEB_CLIENT.post("/render", body: "markdown=hi&page_size=a3",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    ok.status_code.should eq(200)
    ok.headers["Content-Type"].should contain("application/pdf")

    custom = WEB_CLIENT.post("/render", body: "markdown=hi&page_size=100x200",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    custom.status_code.should eq(200)

    bad = WEB_CLIENT.post("/render", body: "markdown=hi&page_size=bogus",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    bad.status_code.should eq(422)
    bad.body.should contain("page size")
  end

  it "answers 422 when markdown is missing" do
    response = WEB_CLIENT.post("/render", body: "style=book",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    response.status_code.should eq(422)
    response.body.should contain("markdown")
  end
end
