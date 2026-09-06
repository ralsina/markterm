# markpdf-web: the project's playground and landing page. A small Kemal
# site where visitors edit markdown, tweak markpdf's styling knobs, and
# watch the PDF update. See src/web.cr for the routes and the render
# pipeline.
require "./web"

port = ENV["PORT"]?.try(&.to_i?) || 3000
Kemal.config.port = port
MarkpdfWeb.start_temp_sweeper
Kemal.run
