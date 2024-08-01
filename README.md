# MARKTerm

Markterm is a library and program to render Markdown to
a terminal. It's inspired by [Glow](https://github.com/charmbracelet/glow)
and implemented using [Markd](https://github.com/icyleaf/markd)

## Features

* If you have [Chroma](https://github.com/alecthomas/chroma)
  it will syntax highlight code blocks
* It will try to handle light and dark terminal themes. Since
  it uses the terminal's colors, it should match things like
  vs code themes in the vs code terminal, etc.
* In general it tries to look good and not gaudy
* It will do the right thing if output is not a tty
* Can be used as a library or as a program

![markterm on a light terminal](markterm-light.png)
![markterm on a dark terminal](markterm-dark.png)



## TODO

* Configurable themes
* ✅ Implement HTML-style links as supported in kitty/alacritty
* ✅ Don't break paragraphs on soft breaks
* ✅ Implement images as supported in kitty (requires timg, kinda buggy)
* ✅ Images in all terminals (requires catimg, kinda useless)
* Fix whatever bug is there

## Usage as a program

Either get a static binary from the [releases page](https://github.com/ralsina/markterm/releases) or build from source:

* Install crystal
* Checkout the repo
* run `make`

This is the help:

```
Markterm - A tool to render markdown to the terminal

Usage:
  markterm <file>
  markterm -h | --help
  markterm --version

Options:
  -h --help     Show this screen.
  --version     Show version.
```

## Usage as a library

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     markterm:
       github: ralsina/markterm
   ```

In your code, use it like this:

```crystal
  puts Markd.to_term(source)
```

## Contributing

1. Fork it (<https://github.com/ralsina/markterm/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Roberto Alsina](https://github.com/ralsina) - creator and maintainer
