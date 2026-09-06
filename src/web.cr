# The markpdf-web playground: a small Kemal site where visitors write
# markdown, tweak markpdf's styling knobs, and see the PDF output live.
# It doubles as the project's landing page, so the whole thing — routes
# included — lives in this file and runs as the markpdf-web binary.
#
# Documents are deliberately ephemeral: they live in the visitor's
# browser (localStorage) and in shareable URLs, never on the server.

require "./pdf"
require "./cli"
require "kemal"
require "ecr"
require "json"

module MarkpdfWeb
  class ParamError < Exception
  end

  class QueueFullError < Exception
  end

  class RenderTimeoutError < Exception
  end

  # Rendering runs through the C++ shim and libharu, whose
  # thread-safety is unknown, and markpdf's font and emoji font
  # registration are process-global. Serialize renders instead of
  # finding out the hard way.
  RENDER_MUTEX = Mutex.new

  # How many requests may be waiting for (or running) a render before
  # the server starts answering 429.
  BUSY_RENDERS = Atomic(Int32).new(0)

  # All limits are env-tunable so a deployment can tighten them without
  # a recompile.
  MAX_MARKDOWN_KB      = env_int("MARKPDF_WEB_MAX_MARKDOWN_KB", 512)
  MAX_MARKDOWN_BYTES   = MAX_MARKDOWN_KB * 1024
  MAX_TEXT_FIELD_CHARS = 500
  MAX_CSS_BYTES        = 64 * 1024
  MAX_RENDER_WAIT      = env_int("MARKPDF_WEB_MAX_QUEUE", 8)
  RENDER_TIMEOUT       = env_int("MARKPDF_WEB_MAX_RENDER_SECONDS", 30).seconds
  PAGE_SIZES           = %w[a4 letter]
  LANGUAGES            = %w[en es]

  # Local/relative image sources resolve against this directory, which
  # is created empty and never written to: server files must not be
  # reachable as "images" through a submitted markdown.
  EMPTY_BASE_DIR = begin
    dir = File.join(Dir.tempdir, "markpdf-web-no-local-images")
    Dir.mkdir_p(dir)
    dir
  end

  def self.env_int(name : String, default : Int32) : Int32
    ENV[name]?.try(&.to_i?) || default
  end

  struct RenderParams
    getter markdown : String
    getter style : String
    getter theme : String?
    getter code_theme : String?
    getter page_size : String
    getter margin_mm : Float64
    getter header : String
    getter footer : String
    getter? pageless : Bool
    getter? hyphenate : Bool
    getter language : String
    getter custom_css : String?

    def initialize(@markdown, @style, @theme, @code_theme, @page_size,
                   @margin_mm, @header, @footer, @pageless, @hyphenate,
                   @language, @custom_css)
    end

    # Parse the knobs from a submitted form. Every field is optional and
    # falls back to the markpdf CLI default, so a bare form with just a
    # markdown body renders fine. Raises ParamError with a
    # user-presentable message when a value is out of range.
    def self.from_form(form : HTTP::Params) : RenderParams
      markdown = form["markdown"]?
      raise ParamError.new("a 'markdown' field is required") unless markdown

      if markdown.bytesize > MAX_MARKDOWN_BYTES
        raise ParamError.new("markdown is too large (limit: #{MAX_MARKDOWN_KB} KB)")
      end

      style = form.fetch("style", "default")
      unless Markd::Pdf.style_names.includes?(style)
        raise ParamError.new("unknown style '#{style}'")
      end

      page_size = form.fetch("page_size", "a4")
      unless PAGE_SIZES.includes?(page_size)
        raise ParamError.new("unknown page size '#{page_size}'")
      end

      margin_mm = parse_margin(form["margin"]?)
      language = form.fetch("language", "en")
      unless LANGUAGES.includes?(language)
        raise ParamError.new("unknown hyphenation language '#{language}'")
      end

      new(
        markdown: markdown,
        style: style,
        theme: blank_to_nil(clean_text(form["theme"]?)),
        code_theme: blank_to_nil(clean_text(form["code_theme"]?)),
        page_size: page_size,
        margin_mm: margin_mm,
        header: clean_text(form["header"]?),
        footer: clean_text(form["footer"]?),
        pageless: truthy?(form["pageless"]?),
        hyphenate: truthy?(form["hyphenate"]?),
        language: language,
        custom_css: clean_css(form["custom_css"]?),
      )
    end

    private def self.parse_margin(value : String?) : Float64
      return 20.0 unless value
      margin = value.to_f?
      unless margin && margin >= 0 && margin <= 100
        raise ParamError.new("margin must be a number between 0 and 100 (millimeters)")
      end
      margin
    end

    private def self.truthy?(value : String?) : Bool
      value ? %w[1 true on yes].includes?(value.downcase) : false
    end

    private def self.clean_text(value : String?) : String
      (value || "").strip[0, MAX_TEXT_FIELD_CHARS]
    end

    private def self.clean_css(value : String?) : String?
      css = value || ""
      raise ParamError.new("custom CSS is too large") if css.bytesize > MAX_CSS_BYTES
      blank_to_nil(css)
    end

    private def self.blank_to_nil(value : String?) : String?
      value.try { |text| text.empty? ? nil : text }
    end
  end

  # Render the document to PDF bytes. Writes through a temporary file
  # because that is the shim's interface; callers never see it. Local
  # image sources resolve against an empty directory on purpose: the
  # server's own files must not be reachable as "images".
  @@last_render_seconds = 0.0

  def self.last_render_seconds : Float64
    @@last_render_seconds
  end

  def self.render_to_bytes(render_params : RenderParams) : Bytes
    output_path = File.tempname("markpdf-web", ".pdf")
    RENDER_MUTEX.synchronize do
      options = Markd::Options.new
      options.gfm = true
      elapsed = Time.measure do
        Markd::Pdf.render(
          render_params.markdown,
          output_path,
          options: options,
          page_size: render_params.page_size,
          margin_mm: render_params.margin_mm,
          base_dir: EMPTY_BASE_DIR,
          header: render_params.header,
          footer: render_params.footer,
          code_theme: Markd::Pdf.pick_code_theme(
            render_params.code_theme,
            render_params.theme,
            render_params.style,
          ),
          theme: render_params.theme,
          style: render_params.style,
          pageless: render_params.pageless?,
          hyphenate: render_params.hyphenate?,
          language: render_params.language,
          css: render_params.custom_css,
        )
      end
      @@last_render_seconds = elapsed.total_seconds
      File.read(output_path).to_slice
    ensure
      File.delete?(output_path)
    end
  end

  # Rendering cannot be interrupted once started (the C shim has no
  # cancellation), but the client does not have to wait forever: the
  # render runs in a fiber and this returns 503 when it outlives
  # RENDER_TIMEOUT. The abandoned fiber finishes on its own and the
  # render mutex stays fair for whoever is next.
  def self.render_to_bytes_limited(render_params : RenderParams) : Bytes
    if BUSY_RENDERS.add(1) + 1 > MAX_RENDER_WAIT
      raise QueueFullError.new("the renderer is busy, try again shortly")
    end
    result = Channel(Bytes | Exception).new
    spawn do
      result.send(render_to_bytes(render_params))
    rescue error
      result.send(error)
    end
    pdf_bytes = select
    when delivered = result.receive
      raise delivered if delivered.is_a?(Exception)
      delivered.as(Bytes)
    when timeout(RENDER_TIMEOUT)
      raise RenderTimeoutError.new("rendering took longer than #{RENDER_TIMEOUT.total_seconds} seconds")
    end
    pdf_bytes
  ensure
    BUSY_RENDERS.sub(1)
  end

  # Renders write through temp files that are deleted the moment their
  # bytes are read; a crash mid-render could still leave orphans, so a
  # sweeper removes anything with our prefix that has outlived its age.
  def self.sweep_temp_pdfs(dir : String = Dir.tempdir, max_age : Time::Span = 1.hour) : Int32
    removed = 0
    Dir.glob(File.join(dir, "markpdf-web*.pdf")).each do |path|
      next unless info = File.info?(path)
      next unless Time.utc - info.modification_time > max_age
      File.delete?(path)
      removed += 1
    end
    removed
  rescue
    0
  end

  def self.start_temp_sweeper(interval : Time::Span = 10.minutes) : Nil
    spawn do
      loop do
        sleep interval
        begin
          sweep_temp_pdfs
        rescue
          # a failed sweep must never kill the sweeper fiber
        end
      end
    end
  end

  # The base16 themes sixteen ships: the page-theme choices. Theme names
  # from tartrazine's own roster (e.g. "monokai") color code blocks but
  # not the page, so they are not offered here.
  def self.page_themes : Array(String)
    names = Set(String).new
    Sixteen::DataFiles.files.each do |data_file|
      filename = File.basename(data_file.path)
      next unless filename.ends_with?(".yaml") || filename.ends_with?(".yml")
      names << filename.sub(/\.(yaml|yml)$/, "")
    end
    names.to_a.sort
  end

  SAMPLES = [
    {
      title: "Feature tour", style: "default", pageless: false,
      markdown: <<-MD
        # markpdf feature tour

        Everything in this document is plain **Markdown**, rendered to PDF
        by *markpdf* — no LaTeX, no word processor, no online service.

        ## GFM goodness

        Tables, of course:

        | Feature    | Status |
        |------------|--------|
        | Tables     | ✅     |
        | Footnotes  | ✅[^1] |
        | Task lists | ✅     |

        - [x] works in tables
        - [ ] and in lists

        > Blockquotes look nice, too — perfect for pull quotes and asides.

        > [!NOTE]
        > GitHub-style alerts are supported: note, tip, important,
        > warning, caution.

        ## Code, highlighted

        ```crystal
        def fib(n : Int32) : Int64
          n < 2 ? 1i64 : fib(n - 1) + fib(n - 2)
        end

        puts fib(40)
        ```

        ## Math

        Euler was here: $e^{ipi} + 1 = 0$

        $$E = mc^2$$

        ## Emoji 🎉 and [links](https://github.com/ralsina/markterm)

        Now play with the knobs: switch the **style**, pick a base16
        **theme**, toggle **hyphenation**, set a **header** or **footer**,
        or check **pageless** for one long page.

        [^1]: Yes, real footnotes with backlinks.
        MD
    },
    {
      title: "Book excerpt", style: "book", pageless: false,
      markdown: <<-MD
        # The Great Gatsby

        ### F. Scott Fitzgerald

        > Then wear the gold hat, if that will move her\\
        > If you can bounce high, bounce for her too\\
        > Till she cry “Lover, gold-hatted, high-bouncing lover,\\
        > I must have you!”
        >
        > — *Thomas Parke d’Invilliers*

        ## I

        In my younger and more vulnerable years my father gave me some advice
        that I’ve been turning over in my mind ever since.

        “Whenever you feel like criticizing anyone,” he told me, “just remember
        that all the people in this world haven’t had the advantages that you’ve
        had.”

        He didn’t say any more, but we’ve always been unusually communicative in
        a reserved way, and I understood that he meant a great deal more than
        that. In consequence, I’m inclined to reserve all judgements, a habit
        that has opened up many curious natures to me and also made me the
        victim of not a few veteran bores. The abnormal mind is quick to detect
        and attach itself to this quality when it appears in a normal person,
        and so it came about that in college I was unjustly accused of being a
        politician, because I was privy to the secret griefs of wild, unknown
        men. Most of the confidences were unsought—frequently I have feigned
        sleep, preoccupation, or a hostile levity when I realized by some
        unmistakable sign that an intimate revelation was quivering on the
        horizon; for the intimate revelations of young men, or at least the
        terms in which they express them, are usually plagiaristic and marred by
        obvious suppressions. Reserving judgements is a matter of infinite hope.
        I am still a little afraid of missing something if I forget that, as my
        father snobbishly suggested, and I snobbishly repeat, a sense of the
        fundamental decencies is parcelled out unequally at birth.

        And, after boasting this way of my tolerance, I come to the admission
        that it has a limit. Conduct may be founded on the hard rock or the wet
        marshes, but after a certain point I don’t care what it’s founded on.
        When I came back from the East last autumn I felt that I wanted the
        world to be in uniform and at a sort of moral attention forever; I
        wanted no more riotous excursions with privileged glimpses into the
        human heart. Only Gatsby, the man who gives his name to this book, was
        exempt from my reaction—Gatsby, who represented everything for which I
        have an unaffected scorn. If personality is an unbroken series of
        successful gestures, then there was something gorgeous about him, some
        heightened sensitivity to the promises of life, as if he were related to
        one of those intricate machines that register earthquakes ten thousand
        miles away. This responsiveness had nothing to do with that flabby
        impressionability which is dignified under the name of the “creative
        temperament”—it was an extraordinary gift for hope, a romantic readiness
        such as I have never found in any other person and which it is not
        likely I shall ever find again. No—Gatsby turned out all right at the
        end; it is what preyed on Gatsby, what foul dust floated in the wake of
        his dreams that temporarily closed out my interest in the abortive
        sorrows and short-winded elations of men.

        *Excerpt from Chapter I, public domain via Project Gutenberg.*
        MD
    },
    {
      title: "Screen reading", style: "dark", pageless: true,
      markdown: <<-MD
        # Reading, not printing

        Paper wants margins and page breaks. Screens want one long,
        scrollable page that gets out of the way. The **pageless** knob
        gives markpdf a screen brain: a single page exactly as tall as
        the document, with headers and footers turned off.

        ## What to notice

        - Light text on a dark page, easy on the eyes
        - Code that does not glow: the dark style picks a matching
          syntax theme automatically

        ```python
        def dark_mode(matters: bool = False) -> str:
            return "easier on the eyes"
        ```

        > [!TIP]
        > Pageless output is great for sharing in chats and reading in
        > the browser's PDF viewer — and exactly wrong for the printer,
        > which is why it is a knob and not a default.
        MD
    },
  ]

  struct LandingPage
    getter styles : Array(NamedTuple(name: String, description: String))
    getter page_themes : Array(String)
    getter code_themes : Array(String)
    getter samples_json : String

    def initialize
      @styles = Markd::Pdf.style_names.map do |name|
        {name: name, description: Markd::Pdf.style_description(name)}
      end
      @page_themes = MarkpdfWeb.page_themes
      @code_themes = Tartrazine.themes
      # Sample documents travel inside a <script> tag: escape "<" so
      # markdown code fences can never close it early.
      @samples_json = SAMPLES.to_json.gsub("<", "\\u003c")
    end

    ECR.def_to_s "#{__DIR__}/views/landing.ecr"
  end
end

get "/" do |env|
  env.response.content_type = "text/html; charset=utf-8"
  MarkpdfWeb::LandingPage.new.to_s
end

post "/render" do |env|
  pdf_bytes = Bytes.new(0)
  begin
    render_params = MarkpdfWeb::RenderParams.from_form(env.params.body)
    pdf_bytes = MarkpdfWeb.render_to_bytes_limited(render_params)
  rescue error : MarkpdfWeb::ParamError | Markd::Pdf::Error
    env.response.content_type = "text/plain; charset=utf-8"
    halt env, status_code: 422, response: error.message || "could not render this document"
  rescue error : MarkpdfWeb::QueueFullError
    env.response.headers.add("Retry-After", "5")
    env.response.content_type = "text/plain; charset=utf-8"
    halt env, status_code: 429, response: error.message
  rescue error : MarkpdfWeb::RenderTimeoutError
    env.response.headers.add("Retry-After", "10")
    env.response.content_type = "text/plain; charset=utf-8"
    halt env, status_code: 503, response: error.message
  end

  render_seconds = MarkpdfWeb.last_render_seconds
  env.response.content_type = "application/pdf"
  env.response.headers.add("Content-Disposition", %(inline; filename="markpdf.pdf"))
  env.response.headers.add("X-Render-Time", render_seconds.round(2).to_s)
  env.response.write(pdf_bytes)
end
