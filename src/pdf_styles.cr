# Built-in stylesheets for markpdf: the "personalities" a document can
# have, selectable with --style / Markd::Pdf.style=. Written against the
# CSS subset litehtml supports (no CSS variables, no grid, no
# page-break-*). Every style covers the same property set so they
# interchange cleanly and an edited copy fed back through --css behaves
# as "my copy, with the built-in plugging any holes".
#
# Layering: the selected style is the base; theme (-t) and user CSS
# (--css) are appended after it and win on equal specificity. The shim
# paints the page background from the body background-color rule, so
# the dark/sepia page colors need no C++ support.
module Markd
  module Pdf
    # Syntax highlighting theme used for the dark style when neither
    # --code-theme nor -t is given: the light default would glow on a
    # dark page.
    DARK_CODE_THEME = "monokai"

    STYLE_DESCRIPTIONS = {
      "default" => "clean sans-serif print style",
      "book"    => "serif, justified, indented — for long prose / e-readers",
      "dark"    => "dark page, light text — for screen reading",
      "sepia"   => "warm paper tones, serif — e-reader default look",
    }

    STYLES = {
      "default" => <<-CSS,
        body { font-family: "DejaVu Sans", Helvetica, Arial, sans-serif; font-size: 11px; line-height: 1.5; color: #1a1a1a; margin: 0; padding: 0; }
        h1 { font-size: 25px; font-weight: bold; margin: 20px 0 12px 0; }
        h2 { font-size: 19px; font-weight: bold; margin: 18px 0 10px 0; }
        h3 { font-size: 15px; font-weight: bold; margin: 16px 0 8px 0; }
        h4 { font-size: 12px; font-weight: bold; margin: 14px 0 8px 0; }
        h5 { font-size: 11px; font-weight: bold; margin: 12px 0 6px 0; }
        h6 { font-size: 11px; font-weight: bold; color: #555555; margin: 12px 0 6px 0; }
        p { margin: 0 0 9px 0; }
        a { color: #0645ad; }
        strong { font-weight: bold; }
        em { font-style: italic; }
        del { text-decoration: line-through; }
        ul, ol { margin: 0 0 9px 0; padding-left: 18px; }
        ul ul, ol ol, ul ol, ol ul { margin: 0 0 9px 0; padding-left: 16px; }
        li { margin: 0 0 3px 0; }
        li.task-list-item { list-style-type: none; }
        blockquote { border-left: 3px solid #cccccc; margin: 9px 0 9px 4px; padding: 2px 0 2px 12px; color: #444444; }
        blockquote p { margin: 0 0 6px 0; }
        pre { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #f6f6f6; border: 1px solid #e0e0e0;
              margin: 9px 0 9px 0; padding: 7px 9px 7px 9px; overflow: hidden;
              white-space: pre-wrap; }
        table { overflow: hidden; }
        code { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #f2f2f2; padding: 0px 2px 0px 2px; }
        pre code { background-color: transparent; padding: 0; }
        table { border-spacing: 0; margin: 9px 0 9px 0; font-size: 10.5px; }
        th { font-weight: bold; border: 1px solid #cccccc; background-color: #f2f2f2; padding: 4px 8px 4px 8px; text-align: left; }
        td { border: 1px solid #cccccc; padding: 4px 8px 4px 8px; }
        hr { border-bottom: 1px solid #bbbbbb; margin: 18px 0 18px 0; }
        img { margin: 6px 0 6px 0; max-width: 100%; }
        .alert { border: 1px solid #bbbbbb; border-left: 4px solid #666666; padding: 8px 12px 4px 12px; margin: 9px 0 9px 0; }
        .alert p { margin: 0 0 6px 0; }
        .alert-title { font-weight: bold; }
        .alert-note { border-left: 4px solid #2e6f9e; }
        .alert-tip { border-left: 4px solid #2e9e5b; }
        .alert-important { border-left: 4px solid #7e4fd0; }
        .alert-warning { border-left: 4px solid #d0962e; }
        .alert-caution { border-left: 4px solid #d0342c; }
        .footnotes { border-top: 1px solid #bbbbbb; margin-top: 18px; font-size: 10px; color: #444444; }
        CSS
      "book" => <<-CSS,
        body { font-family: "DejaVu Serif", Georgia, serif; font-size: 12px; line-height: 1.6; color: #1a1a1a; margin: 0; padding: 0; }
        h1, h2, h3 { text-align: center; }
        h1 { font-size: 24px; font-weight: bold; margin: 26px 0 18px 0; }
        h2 { font-size: 19px; font-weight: bold; margin: 20px 0 12px 0; }
        h3 { font-size: 15px; font-weight: bold; margin: 16px 0 8px 0; }
        h4 { font-size: 12px; font-weight: bold; margin: 14px 0 8px 0; }
        h5 { font-size: 11.5px; font-weight: bold; margin: 12px 0 6px 0; }
        h6 { font-size: 11.5px; font-style: italic; color: #555555; margin: 12px 0 6px 0; }
        p { margin: 0; text-indent: 1.5em; text-align: justify; }
        a { color: #0645ad; }
        strong { font-weight: bold; }
        em { font-style: italic; }
        del { text-decoration: line-through; }
        ul, ol { margin: 0 0 9px 0; padding-left: 18px; }
        ul ul, ol ol, ul ol, ol ul { margin: 0 0 9px 0; padding-left: 16px; }
        li { margin: 0 0 3px 0; text-align: justify; }
        li.task-list-item { list-style-type: none; }
        li p { margin: 0 0 3px 0; text-indent: 0; }
        blockquote { border-left: 3px solid #cccccc; margin: 9px 0 9px 0; padding: 2px 0 2px 12px; color: #444444; font-size: 11.5px; }
        blockquote p { margin: 0 0 6px 0; text-indent: 0; }
        pre { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #f6f6f6; border: none;
              margin: 9px 0 9px 0; padding: 7px 9px 7px 9px; overflow: hidden;
              white-space: pre-wrap; }
        table { overflow: hidden; }
        code { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #f2f2f2; padding: 0px 2px 0px 2px; }
        pre code { background-color: transparent; padding: 0; }
        table { border-spacing: 0; margin: 9px 0 9px 0; font-size: 10.5px; }
        th { font-weight: bold; border: 1px solid #cccccc; background-color: #f2f2f2; padding: 4px 8px 4px 8px; text-align: left; }
        td { border: 1px solid #cccccc; padding: 4px 8px 4px 8px; }
        hr { border-bottom: 1px solid #bbbbbb; margin: 18px 0 18px 0; }
        img { margin: 6px 0 6px 0; max-width: 100%; }
        .alert { border: 1px solid #bbbbbb; border-left: 4px solid #666666; padding: 8px 12px 4px 12px; margin: 9px 0 9px 0; font-size: 11.5px; }
        .alert p { margin: 0 0 6px 0; text-indent: 0; }
        .alert-title { font-weight: bold; }
        .alert-note { border-left: 4px solid #2e6f9e; }
        .alert-tip { border-left: 4px solid #2e9e5b; }
        .alert-important { border-left: 4px solid #7e4fd0; }
        .alert-warning { border-left: 4px solid #d0962e; }
        .alert-caution { border-left: 4px solid #d0342c; }
        .footnotes { border-top: 1px solid #bbbbbb; margin-top: 18px; font-size: 10px; color: #444444; }
        CSS
      "dark" => <<-CSS,
        body { font-family: "DejaVu Sans", Helvetica, Arial, sans-serif; font-size: 11px; line-height: 1.5; color: #e8e8e8; background-color: #121212; margin: 0; padding: 0; }
        h1 { font-size: 25px; font-weight: bold; margin: 20px 0 12px 0; }
        h2 { font-size: 19px; font-weight: bold; margin: 18px 0 10px 0; }
        h3 { font-size: 15px; font-weight: bold; margin: 16px 0 8px 0; }
        h4 { font-size: 12px; font-weight: bold; margin: 14px 0 8px 0; }
        h5 { font-size: 11px; font-weight: bold; margin: 12px 0 6px 0; }
        h6 { font-size: 11px; font-weight: bold; color: #aaaaaa; margin: 12px 0 6px 0; }
        p { margin: 0 0 9px 0; }
        a { color: #8ab4f8; }
        strong { font-weight: bold; }
        em { font-style: italic; }
        del { text-decoration: line-through; }
        ul, ol { margin: 0 0 9px 0; padding-left: 18px; }
        ul ul, ol ol, ul ol, ol ul { margin: 0 0 9px 0; padding-left: 16px; }
        li { margin: 0 0 3px 0; }
        li.task-list-item { list-style-type: none; }
        blockquote { border-left: 3px solid #444444; margin: 9px 0 9px 4px; padding: 2px 0 2px 12px; color: #bbbbbb; }
        blockquote p { margin: 0 0 6px 0; }
        pre { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #1e1e1e; border: 1px solid #333333;
              margin: 9px 0 9px 0; padding: 7px 9px 7px 9px; overflow: hidden;
              white-space: pre-wrap; }
        table { overflow: hidden; }
        code { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #1e1e1e; padding: 0px 2px 0px 2px; }
        pre code { background-color: transparent; padding: 0; }
        table { border-spacing: 0; margin: 9px 0 9px 0; font-size: 10.5px; }
        th { font-weight: bold; border: 1px solid #444444; background-color: #1e1e1e; padding: 4px 8px 4px 8px; text-align: left; }
        td { border: 1px solid #444444; padding: 4px 8px 4px 8px; }
        hr { border-bottom: 1px solid #444444; margin: 18px 0 18px 0; }
        img { margin: 6px 0 6px 0; max-width: 100%; }
        .alert { border: 1px solid #444444; border-left: 4px solid #888888; padding: 8px 12px 4px 12px; margin: 9px 0 9px 0; }
        .alert p { margin: 0 0 6px 0; }
        .alert-title { font-weight: bold; }
        .alert-note { border-left: 4px solid #6fa8dc; }
        .alert-tip { border-left: 4px solid #6fbf8b; }
        .alert-important { border-left: 4px solid #a98fe0; }
        .alert-warning { border-left: 4px solid #e0b05e; }
        .alert-caution { border-left: 4px solid #e0645a; }
        .footnotes { border-top: 1px solid #444444; margin-top: 18px; font-size: 10px; color: #bbbbbb; }
        CSS
      "sepia" => <<-CSS
        body { font-family: "DejaVu Serif", Georgia, serif; font-size: 12px; line-height: 1.6; color: #5b4636; background-color: #f4ecd8; margin: 0; padding: 0; }
        h1 { font-size: 24px; font-weight: bold; margin: 20px 0 12px 0; }
        h2 { font-size: 19px; font-weight: bold; margin: 18px 0 10px 0; }
        h3 { font-size: 15px; font-weight: bold; margin: 16px 0 8px 0; }
        h4 { font-size: 12px; font-weight: bold; margin: 14px 0 8px 0; }
        h5 { font-size: 11.5px; font-weight: bold; margin: 12px 0 6px 0; }
        h6 { font-size: 11.5px; font-style: italic; color: #8a7a5a; margin: 12px 0 6px 0; }
        p { margin: 0 0 9px 0; }
        a { color: #7a5c2e; }
        strong { font-weight: bold; }
        em { font-style: italic; }
        del { text-decoration: line-through; }
        ul, ol { margin: 0 0 9px 0; padding-left: 18px; }
        ul ul, ol ol, ul ol, ol ul { margin: 0 0 9px 0; padding-left: 16px; }
        li { margin: 0 0 3px 0; }
        li.task-list-item { list-style-type: none; }
        blockquote { border-left: 3px solid #d3c3a0; margin: 9px 0 9px 4px; padding: 2px 0 2px 12px; color: #6e5744; }
        blockquote p { margin: 0 0 6px 0; }
        pre { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #ece1c6; border: 1px solid #d3c3a0;
              margin: 9px 0 9px 0; padding: 7px 9px 7px 9px; overflow: hidden;
              white-space: pre-wrap; }
        table { overflow: hidden; }
        code { font-family: "DejaVu Sans Mono", "Liberation Mono", Courier, monospace; font-size: 10px; background-color: #ece1c6; padding: 0px 2px 0px 2px; }
        pre code { background-color: transparent; padding: 0; }
        table { border-spacing: 0; margin: 9px 0 9px 0; font-size: 10.5px; }
        th { font-weight: bold; border: 1px solid #d3c3a0; background-color: #ece1c6; padding: 4px 8px 4px 8px; text-align: left; }
        td { border: 1px solid #d3c3a0; padding: 4px 8px 4px 8px; }
        hr { border-bottom: 1px solid #d3c3a0; margin: 18px 0 18px 0; }
        img { margin: 6px 0 6px 0; max-width: 100%; }
        .alert { border: 1px solid #d3c3a0; border-left: 4px solid #8a7a5a; padding: 8px 12px 4px 12px; margin: 9px 0 9px 0; }
        .alert p { margin: 0 0 6px 0; }
        .alert-title { font-weight: bold; }
        .alert-note { border-left: 4px solid #4e6f8e; }
        .alert-tip { border-left: 4px solid #4e8e5e; }
        .alert-important { border-left: 4px solid #7a5fa8; }
        .alert-warning { border-left: 4px solid #a8823e; }
        .alert-caution { border-left: 4px solid #a84e42; }
        .footnotes { border-top: 1px solid #d3c3a0; margin-top: 18px; font-size: 10px; color: #6e5744; }
        CSS
    }

    # The original name of the base stylesheet, kept for compatibility.
    DEFAULT_CSS = STYLES["default"]

    @@css : String = DEFAULT_CSS
    @@style : String = "default"

    # Names of the built-in styles, in roster order.
    def self.style_names : Array(String)
      STYLES.keys
    end

    # Human-readable one-line description shown by --list-styles.
    def self.style_description(name : String) : String
      STYLE_DESCRIPTIONS[name]? ||
        raise Error.new("unknown style '#{name}' (available: #{STYLES.keys.join(", ")})")
    end

    # The raw stylesheet text of a built-in style (what --print-style
    # prints). Raises Error on an unknown name.
    def self.style_css(name : String) : String
      STYLES[name]? ||
        raise Error.new("unknown style '#{name}' (available: #{STYLES.keys.join(", ")})")
    end

    # The style the base stylesheet currently comes from.
    def self.style : String
      @@style
    end

    # Select the base stylesheet and reset the rendered CSS to it.
    # Layers added with css= are dropped: set them again afterwards.
    # Raises Error on an unknown name.
    def self.style=(name : String) : Nil
      css = style_css(name) # raises Error on an unknown name
      @@style = name
      @@css = css
    end

    # Extend the current stylesheet (e.g. from a --css flag): the
    # selected style's rules come first, the argument's last, so the
    # argument wins on equal specificity.
    def self.css=(user_css : String)
      @@css = style_css(@@style) + "\n" + user_css
    end

    def self.css : String
      @@css
    end

    # Reset the rendered CSS to the selected style (dropping any layers
    # added with css=).
    def self.reset_css : Nil
      @@css = style_css(@@style)
    end
  end
end
