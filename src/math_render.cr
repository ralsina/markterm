# Math rendering helpers shared by the renderers.
#
# Two layers:
# - Display math ($$...$$) renders as UTF-8 text art through the shim's
#   litepdf_render_math, which links the GPL-3 libtexprintf when the
#   native build enabled WITH_TEXMATH (the default), in a mono pre
#   block. Without it — and for inline math everywhere — a styling
#   pass converts common LaTeX to Unicode symbols with real
#   sub/superscripts.
module MathRender
  # LaTeX commands mapped to Unicode symbols (or HTML-safe entities
  # for the HTML renderer). Keys include the leading backslash;
  # substitution is longest-first.
  COMMANDS = {
    "\\infty" => "∞", "\\int" => "∫", "\\sum" => "∑", "\\prod" => "∏",
    "\\partial" => "∂", "\\nabla" => "∇", "\\sqrt" => "√",
    "\\times" => "×", "\\div" => "÷", "\\pm" => "±", "\\cdot" => "⋅",
    "\\leq" => "≤", "\\geq" => "≥", "\\neq" => "≠", "\\ne" => "≠",
    "\\approx" => "≈", "\\equiv" => "≡", "\\sim" => "∼", "\\propto" => "∝",
    "\\rightarrow" => "→", "\\to" => "→", "\\leftarrow" => "←",
    "\\Rightarrow" => "⇒", "\\Leftarrow" => "⇐", "\\uparrow" => "↑",
    "\\downarrow" => "↓", "\\ldots" => "…", "\\dots" => "…", "\\cdots" => "⋯",
    "\\alpha" => "α", "\\beta" => "β", "\\gamma" => "γ", "\\delta" => "δ",
    "\\epsilon" => "ε", "\\varepsilon" => "ε", "\\zeta" => "ζ", "\\eta" => "η",
    "\\theta" => "θ", "\\vartheta" => "ϑ", "\\iota" => "ι", "\\kappa" => "κ",
    "\\lambda" => "λ", "\\mu" => "μ", "\\nu" => "ν", "\\xi" => "ξ",
    "\\pi" => "π", "\\rho" => "ρ", "\\sigma" => "σ", "\\tau" => "τ",
    "\\upsilon" => "υ", "\\phi" => "φ", "\\varphi" => "φ", "\\chi" => "χ",
    "\\psi" => "ψ", "\\omega" => "ω",
    "\\Gamma" => "Γ", "\\Delta" => "Δ", "\\Theta" => "Θ", "\\Lambda" => "Λ",
    "\\Xi" => "Ξ", "\\Pi" => "Π", "\\Sigma" => "Σ", "\\Phi" => "Φ",
    "\\Psi" => "Ψ", "\\Omega" => "Ω",
    "\\degree" => "°", "\\circ" => "∘", "\\ell" => "ℓ", "\\hbar" => "ℏ",
    "\\forall" => "∀", "\\exists" => "∃", "\\in" => "∈", "\\notin" => "∉",
    "\\subset" => "⊂", "\\supset" => "⊃", "\\subseteq" => "⊆",
    "\\supseteq" => "⊇", "\\cup" => "∪", "\\cap" => "∩", "\\emptyset" => "∅",
    "\\land" => "∧", "\\lor" => "∨", "\\neg" => "¬", "\\angle" => "∠",
    "\\perp" => "⊥", "\\parallel" => "∥",
    "\\quad" => "&emsp;", "\\qquad" => "&emsp;&emsp;", "\\," => "&thinsp;",
    "\\;" => "&thinsp;", "\\:" => " ", "\\ " => " ",
    "\\{" => "&#123;", "\\}" => "&#125;", "\\_" => "&#95;",
    "\\^" => "&#94;", "\\$" => "&#36;", "\\&" => "&amp;", "\\#" => "&#35;",
    "\\%" => "&#37;", "\\\\" => "\n",
  }

  # Unicode super/subscripts for the terminal renderer, where HTML
  # sub/sup is not available (single characters only).
  SUPERSCRIPT = {
    '0' => "⁰", '1' => "¹", '2' => "²", '3' => "³", '4' => "⁴",
    '5' => "⁵", '6' => "⁶", '7' => "⁷", '8' => "⁸", '9' => "⁹",
    '+' => "⁺", '-' => "⁻", '=' => "⁼", '(' => "⁽", ')' => "⁾",
    'n' => "ⁿ", 'i' => "ⁱ",
  }
  SUBSCRIPT = {
    '0' => "₀", '1' => "₁", '2' => "₂", '3' => "₃", '4' => "₄",
    '5' => "₅", '6' => "₆", '7' => "₇", '8' => "₈", '9' => "₉",
    '+' => "₊", '-' => "₋", '=' => "₌", '(' => "₍", ')' => "₎",
    'a' => "ₐ", 'e' => "ₑ", 'o' => "ₒ", 'x' => "ₓ",
  }

  def self.commands_regex : Regex
    @@commands_regex ||= begin
      keys = COMMANDS.keys.sort_by!(&.size).reverse!
      Regex.new("\\\\(?:" + keys.map { |k| Regex.escape(k[1..]) }.join("|") + ")")
    end
  end

  # Replace LaTeX commands with their Unicode symbols.
  def self.substitute_commands(s : String) : String
    s.gsub(commands_regex) { |match| COMMANDS[match]? || match }
  end

  # Drop environment markers and grouping braces that only carry
  # meaning in real math layout.
  def self.cleanup(s : String) : String
    s = s.gsub(/\\(?:begin|end)\{[^{}]*\}/, "")
    s = s.gsub(/\\(?:left|right)/, "")
    s = s.gsub(/\\frac\{([^{}]*)\}\{([^{}]*)\}/, "\\1/\\2")
    s = s.gsub(/[{}]/, "")
    s
  end

  # HTML styling pass: Unicode symbols plus real sub/superscripts.
  # Input is HTML-escaped text from the generated document; the output
  # introduces no unescaped characters.
  def self.stylize_html(latex : String) : String
    s = substitute_commands(latex)
    s = cleanup(s)
    s = s.gsub(/\^\{([^{}]*)\}/, "<sup>\\1</sup>")
    s = s.gsub(/\^(-?[^\s{}])/) { |_, match| "<sup>#{match[1]}</sup>" }
    s = s.gsub(/_\{([^{}]*)\}/, "<sub>\\1</sub>")
    s = s.gsub(/_(-?[^\s{}])/) { |_, match| "<sub>#{match[1]}</sub>" }
    s
  end

  # Plain-text pass for the terminal renderer: Unicode symbols plus
  # Unicode super/subscripts where a mapping exists. Entities produced
  # by the command table decode to real characters.
  def self.unicode(latex : String) : String
    s = substitute_commands(latex)
    s = cleanup(s)
    s = s.gsub(/\^\{([^{}]*)\}/) { |text, match| superscript(match[1]) || text }
    s = s.gsub(/\^(-?[^\s{}])/) { |text, match| superscript(match[1]) || text }
    s = s.gsub(/_\{([^{}]*)\}/) { |text, match| subscript(match[1]) || text }
    s = s.gsub(/_(-?[^\s{}])/) { |text, match| subscript(match[1]) || text }
    decode_entities(s)
  end

  private def self.decode_entities(s : String) : String
    s.gsub("&emsp;", " ")
      .gsub("&thinsp;", " ")
      .gsub("&#123;", "{")
      .gsub("&#125;", "}")
      .gsub("&#95;", "_")
      .gsub("&#94;", "^")
      .gsub("&#36;", "$")
      .gsub("&#35;", "#")
      .gsub("&#37;", "%")
      .gsub("&amp;", "&")
  end

  private def self.superscript(s : String) : String?
    return SUPERSCRIPT[s[0]]? if s.size == 1
    s.chars.map { |character| SUPERSCRIPT[character]? || character }.join if s.size <= 4
  end

  private def self.subscript(s : String) : String?
    return SUBSCRIPT[s[0]]? if s.size == 1
    s.chars.map { |character| SUBSCRIPT[character]? || character }.join if s.size <= 4
  end

  # Display art comes from the shim's litepdf_render_math, which links
  # libtexprintf when the native build enabled WITH_TEXMATH and returns
  # NULL otherwise (the Unicode styling pass is the fallback).
  def self.display_art(latex : String) : String?
    ptr = Litepdf.render_math(latex)
    return unless ptr
    art = String.new(ptr)
    Litepdf.free_mem(ptr)
    return if art.strip.empty?
    art.chomp
  end

  # Rewrite display ($$...$$) and inline ($...$) math in generated HTML.
  # Content inside code elements and inside tags is left alone, so code
  # spans and attributes never become math. Display math renders as
  # text art in a mono pre block when libtexprintf is available, with a
  # styled Unicode span as fallback; inline math always uses the
  # styled span.
  SEGMENT_SPLIT = Regex.new("(<code[^>]*>[\\s\\S]*?</code>|<pre[^>]*>[\\s\\S]*?</pre>|<[^>]*>)")
  DISPLAY_MATH  = Regex.new("\\$\\$([\\s\\S]*?)\\$\\$")
  INLINE_MATH   = Regex.new("\\$(?=[^\\s\\d])([^$\\n]*?[^\\s$])\\$(?!\\d)")
  PLACEHOLDER   = Regex.new("\uE000(\\d+)\uE001")

  # Rewrite display ($$...$$) and inline ($...$) math in generated HTML.
  # Content inside code elements and inside tags is left alone, so code
  # spans and attributes never become math. Display math renders as
  # text art in a mono pre block when libtexprintf is available, with a
  # styled Unicode span as fallback; inline math always uses the
  # styled span. Rendered pieces are held aside behind placeholders so
  # later passes cannot re-process them.
  def self.rewrite_html(html : String) : String
    held = [] of String
    rewritten = html.split(SEGMENT_SPLIT).map_with_index do |part, index|
      next part if index.odd? # captured delimiter: tag or code
      part.gsub(DISPLAY_MATH) do |_, match|
        held << display_html(match[1].strip)
        placeholder(held.size - 1)
      end.gsub(INLINE_MATH) do |_, match|
        held << "<span class=\"math\">#{stylize_html(match[1])}</span>"
        placeholder(held.size - 1)
      end
    end
    decode_placeholders(rewritten.join, held)
  end

  # Markdown-source rewrite for the terminal renderer: display math
  # becomes a fenced block holding the rendered art (when available),
  # inline math is converted to Unicode text. Fenced code blocks are
  # skipped.
  def self.rewrite_markdown_math(source : String) : String
    fence_split = Regex.new("(```[^\\n]*\\n[\\s\\S]*?\\n```|```[^\\n]*\\n[\\s\\S]*$)")
    held = [] of String
    rewritten = source.split(fence_split).map_with_index do |part, index|
      next part if index.odd?
      part.gsub(DISPLAY_MATH) do |text, match|
        latex = match[1].strip
        art = display_art(latex)
        held << (art ? "```\n#{art}\n```" : text)
        placeholder(held.size - 1)
      end.gsub(INLINE_MATH) do |_, match|
        held << unicode(match[1])
        placeholder(held.size - 1)
      end
    end
    decode_placeholders(rewritten.join, held)
  end

  private def self.placeholder(index : Int) : String
    "#{0xE000.chr}#{index}#{0xE001.chr}"
  end

  private def self.decode_placeholders(text : String, held : Array(String)) : String
    text.gsub(PLACEHOLDER) do |_, match|
      held[match[1].to_i]
    end
  end

  # Terminal-safe art: escape HTML specials for embedding in HTML.
  def self.escape_html(s : String) : String
    s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
  end

  private def self.display_html(latex : String) : String
    latex = unescape_html(latex)
    if art = display_art(latex)
      "<pre class=\"math\">#{escape_html(art)}</pre>"
    else
      "<span class=\"math block\">#{stylize_html(latex)}</span>"
    end
  end

  private def self.unescape_html(s : String) : String
    s.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", "\"").gsub("&#39;", "'").gsub("&amp;", "&")
  end

  # Markdown-source rewrite for the terminal renderer: display math
  # becomes a fenced block holding the rendered art (when available),
  # inline math is converted to Unicode text. Fenced code blocks are
  # skipped, and display blocks are held aside while inline math is
  # rewritten so art never gets re-processed.
end
