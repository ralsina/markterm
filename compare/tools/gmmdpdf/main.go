// gmmdpdf: minimal CLI around the goldmark-pdf library, mirroring how a
// Go user assembles a markdown-to-PDF binary from parts. GFM extensions
// (tables, strikethrough, task lists, linkify) plus footnotes are on;
// everything else is library default.
package main

import (
	"fmt"
	"os"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"

	pdf "github.com/stephenafamo/goldmark-pdf"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: gmmdpdf <input.md> <output.pdf>")
		os.Exit(2)
	}
	source, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	outFile, err := os.Create(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer outFile.Close()

	md := goldmark.New(
		goldmark.WithExtensions(
			extension.GFM,
			extension.Footnote,
		),
		goldmark.WithRenderer(pdf.New(
			pdf.WithEscapeHTML(false),
		)),
	)
	if err := md.Convert(source, outFile); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
