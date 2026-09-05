require "./spec_helper"

describe MathRender do
  describe ".stylize_html" do
    it "converts inline math to unicode symbols and html sup/sub" do
      MathRender.stylize_html("E = mc^2").should contain("mc<sup>2</sup>")
      MathRender.stylize_html("\\int_0^\\infty").should contain("∫")
      MathRender.stylize_html("\\int_0^\\infty").should contain("<sub>0</sub>")
      MathRender.stylize_html("\\int_0^\\infty").should contain("<sup>∞</sup>")
    end

    it "keeps escaped specials as entities" do
      MathRender.stylize_html("a \\{ b").should contain("&#123;")
      MathRender.stylize_html("100\\$").should contain("&#36;")
    end
  end

  describe ".unicode" do
    it "maps single-character super/subscripts to unicode" do
      MathRender.unicode("E = mc^2").should eq("E = mc²")
      MathRender.unicode("x_1 + y_2").should contain("x₁")
    end

    it "maps latex commands to unicode symbols" do
      MathRender.unicode("\\int_0^\\infty").should contain("∫")
      MathRender.unicode("\\int_0^\\infty").should contain("∞")
    end
  end

  describe ".rewrite_html" do
    it "wraps inline math in a styled span" do
      MathRender.rewrite_html("<p>$E = mc^2$</p>").should contain("<span class=\"math\">E = mc<sup>2</sup></span>")
    end

    it "leaves currency amounts alone" do
      html = "<p>It costs $5, not $10 total.</p>"
      MathRender.rewrite_html(html).should eq(html)
    end

    it "skips code spans" do
      html = "<p><code>$x^2$</code> and $y^3$</p>"
      rewritten = MathRender.rewrite_html(html)
      rewritten.should contain("<code>$x^2$</code>")
      rewritten.should contain("y<sup>3</sup>")
    end
  end

  describe ".rewrite_markdown_math" do
    it "converts inline math to unicode text" do
      MathRender.rewrite_markdown_math("Inline $E = mc^2$ here").should eq("Inline E = mc² here")
    end

    it "leaves fenced code blocks alone" do
      source = "```\n$x^2$\n```"
      MathRender.rewrite_markdown_math(source).should eq(source)
    end

    it "leaves inline code spans alone" do
      source = "keep `$E = mc^2$` and `$$…$$` literal"
      MathRender.rewrite_markdown_math(source).should eq(source)
    end

    it "keeps code spans from swallowing the rest of the paragraph" do
      source = "(`$E = mc^2$` inline, `$$…$$` display) is rendered as styled Unicode."
      rewritten = MathRender.rewrite_markdown_math(source)
      rewritten.should contain("is rendered as styled Unicode")
      rewritten.should contain("$$…$$")
    end
  end
end
