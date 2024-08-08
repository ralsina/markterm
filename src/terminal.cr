require "tartrazine"

module Terminal
  extend self

  def supports_links? : Bool
    STDOUT.tty? && ((["xterm-kitty", "kitty", "alacritty"].includes? ENV["TERM"]) ||
      (ENV["TERM_PROGRAM"] == "vscode"))
  end

  def supports_images? : Bool
    !Process.find_executable("timg").nil? || !Process.find_executable("catimg").nil?
  end

  def terminal_light? : Bool
    # If the COLORFGBG environment variable is set, we can use
    # it to determine the result. It will be something like
    # `15;0` or `0;15`. The first number is the foreground color
    # and the second number is the background color.
    if ["15;0", "15;default;0"].includes?(ENV.fetch("COLORFGBG", ""))
      return true
    end

    # In most linuxy terminals, we can query the terminal's
    # background color by sending an escape sequence.
    # We should only try if we are in a tty
    # and the TERM environment variable is set.
    #
    # This doesn't work in all terminals. For example, alacitty
    # seems to always return black in all queries.
    if !ENV.fetch("TERM", "").empty? && STDOUT.tty? && STDIN.tty?
      bg = parse_color(query_terminal("11"))
      fg = parse_color(query_terminal("10"))

      if bg.nil? # Who knows!
        return false
      end

      # Some terms (alacritty) don't support querying the
      # fg color, so we just guess based on the bg color
      if bg == fg || !fg
        return bg.sum > 384 # Quick and dirty brightness check
      end

      return fg.sum < bg.sum # FG is darker, so term is light
    end
    # Let's just assume it's dark
    false
  end

  def parse_color(color)
    m = /([0-9a-f]+)\/([0-9a-f]+)\/([0-9a-f]+)/.match(color)
    if m.nil?
      return nil
    end
    r = m[0][...2].to_i(16)
    g = m[1][...2].to_i(16)
    b = m[2][...2].to_i(16)
    [r, g, b]
  end

  def query_terminal(color) : String
    STDOUT << "\e]#{color};?\e\\"
    STDOUT.flush
    result = String::Builder.new
    STDIN.raw do |io|
      io.each_char do |chr|
        break if chr == "\a" || chr == '\\'
        result << chr
      end
    end
    result.to_s
  end

  def show_image(path : String) : String
    result = ""
    return result unless supports_images?

    if ENV["TERM"] == "xterm-kitty" && Process.find_executable("timg")
      tmpfile = File.tempname
      Process.run("timg", ["-p", "k", "-o", tmpfile, path], error: STDERR, output: STDERR)
      result = File.read(tmpfile)
    else
      Process.run("catimg", [path, "-w", "256"], output: Process::Redirect::Pipe) do |process|
        result += process.output.gets_to_end
      end
    end
    result
  end

  def highlight(source : String, language : String, theme : String?) : String
    return source unless STDOUT.tty?
    if theme.nil?
      style = terminal_light? ? "base16_papercolor-light" : "base16_papercolor-dark"
    else
      style = "base16_#{theme}"
    end
    theme = Tartrazine.theme(style)
    lexer = Tartrazine.lexer(language)
    Tartrazine::Ansi.new.format(source, lexer, theme)
  end
end
