require "tartrazine"
require "tartrazine/formatters/ansi"

lib LibC
  struct Winsize
    ws_row : UInt16
    ws_col : UInt16
    ws_xpixel : UInt16
    ws_ypixel : UInt16
  end

  fun ioctl(fd : Int32, request : UInt64, ...) : Int32
end

module Terminal
  extend self

  # Get terminal width, with fallback
  # Returns nil if not in a TTY or unable to determine
  def terminal_width : Int32?
    return nil unless STDOUT.tty?

    # Try COLUMNS environment variable first
    if (cols = ENV["COLUMNS"]?.try(&.to_i?)) && cols > 0
      return cols
    end

    # Use ioctl TIOCGWINSZ to get terminal size
    {% if flag?(:linux) %}
      tiocgwinsz = 0x5413_u64
      winsize = LibC::Winsize.new
      ret = LibC.ioctl(1, tiocgwinsz, pointerof(winsize))
      return nil if ret != 0
      cols = winsize.ws_col
      return nil if cols == 0
      cols.to_i32
    {% elsif flag?(:darwin) %}
      tiocgwinsz = 0x40087468_u64
      winsize = LibC::Winsize.new
      ret = LibC.ioctl(1, tiocgwinsz, pointerof(winsize))
      return nil if ret != 0
      cols = winsize.ws_col
      return nil if cols == 0
      cols.to_i32
    {% else %}
      # Fallback for other platforms
      nil
    {% end %}
  end

  def supports_links? : Bool
    STDOUT.tty? && ((["xterm-kitty", "kitty", "alacritty"].includes? ENV["TERM"]) ||
      (ENV.fetch("TERM_PROGRAM", nil) == "vscode"))
  end

  def supports_images? : Bool
    !Process.find_executable("timg").nil?
  end

  def terminal_light? : Bool
    # If the COLORFGBG environment variable is set, we can use
    # it to determine the result. It will be something like
    # `15;0` or `0;15`. The first number is the foreground color
    # and the second number is the background color.
    if ["15;0", "15;default;0"].includes?(ENV.fetch("COLORFGBG", ""))
      return false
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
        break if chr == '\a' || chr == '\\'
        result << chr
      end
    end
    result.to_s
  end

  def show_image(path : String) : String
    result = ""
    return result unless supports_images?

    quantization = "k"
    quantization = "q" unless ENV.fetch("TERM", nil) == "xterm-kitty" && STDOUT.tty?
    if Process.find_executable("timg")
      tmpfile = File.tempname
      Process.run("timg", ["-p", quantization, "-o", tmpfile, path], error: STDERR, output: STDERR)
      result = File.read(tmpfile)
    end
    result
  end

  def highlight(source : String, language : String, theme : String?) : String
    if theme.nil?
      style = terminal_light? ? "papercolor-light" : "papercolor-dark"
    else
      style = "#{theme}"
    end
    formatter = Tartrazine::Ansi.new(theme: Tartrazine.theme(style))
    begin
      lexer = Tartrazine.lexer(language)
    rescue
      lexer = Tartrazine.lexer("plaintext")
    end
    formatter.format(source, lexer)
  end
end
