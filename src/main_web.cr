# markpdf-web: the project's playground and landing page. A small Kemal
# site where visitors edit markdown, tweak markpdf's styling knobs, and
# watch the PDF update. See src/web.cr for the routes and the render
# pipeline.
require "./web"

port = ENV["PORT"]?.try(&.to_i?) || 3000
Kemal.config.port = port

# The demo renders untrusted markdown: remote image fetching stays off
# unless explicitly re-enabled with MARKPDF_WEB_FETCH_IMAGES=1.
Markd::Pdf.fetch_remote_images = ENV["MARKPDF_WEB_FETCH_IMAGES"]? == "1"

Kemal.run
