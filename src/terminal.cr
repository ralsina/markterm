require "tartrazine"
require "tartrazine/formatters/ansi"
require "term-screen"

module Terminal
  extend self

  # Get terminal width, with fallback
  # Returns nil if not in a TTY or unable to determine
  def terminal_width : Int32?
    return unless STDOUT.tty?
    Term::Screen.width
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

  # Parse an X11-style color reply like "rgb:1c1c/1c1c/1c1c"
  # into [red, green, blue], or nil if it doesn't parse
  def parse_color(color) : Array(Int32)?
    match = /([0-9a-fA-F]+)\/([0-9a-fA-F]+)\/([0-9a-fA-F]+)/.match(color)
    return if match.nil?

    red = match[1][...2].to_i(16)
    green = match[2][...2].to_i(16)
    blue = match[3][...2].to_i(16)
    [red, green, blue]
  end

  # Query a terminal color via OSC and read the reply.
  # If the terminal never replies (some don't support the query),
  # time out instead of blocking forever.
  def query_terminal(color) : String
    STDOUT << "\e]#{color};?\e\\"
    STDOUT.flush
    result = String::Builder.new
    STDIN.raw do |io|
      io.read_timeout = 200.milliseconds
      begin
        io.each_char do |chr|
          break if chr == '\a' || chr == '\\'
          result << chr
        end
      rescue IO::TimeoutError
        # No reply; the caller will fall back to its default
      end
    end
    result.to_s
  end

  def show_image(path : String) : String
    return "" unless supports_images?

    quantization = "k"
    quantization = "q" unless ENV.fetch("TERM", nil) == "xterm-kitty" && STDOUT.tty?
    executable = Process.find_executable("timg")
    return "" unless executable

    tmpfile = File.tempname
    begin
      # Discard timg's chatter instead of passing it through to the user
      process = Process.run(executable, ["-p", quantization, "-o", tmpfile, path], error: IO::Memory.new, output: IO::Memory.new)
      process.success? ? File.read(tmpfile) : ""
    ensure
      File.delete(tmpfile) if File.exists?(tmpfile)
    end
  end

  def highlight(source : String, language : String, theme : String?) : String
    style = theme || (terminal_light? ? "papercolor-light" : "papercolor-dark")
    formatter = Tartrazine::Ansi.new(theme: Tartrazine.theme(style))
    begin
      lexer = Tartrazine.lexer(language)
    rescue
      lexer = Tartrazine.lexer("plaintext")
    end
    formatter.format(source, lexer)
  end
end
