# MARKTerm

Markterm is a library and program to render Markdown to
a terminal. It's inspired by [Glow](https://github.com/charmbracelet/glow)
and implemented using [Markd](https://github.com/icyleaf/markd)

## Features

* If you have [Chroma](https://github.com/alecthomas/chroma)
  it will syntax highlight code blocks
* It will try to handle light and dark terminal themes
* In general it tries to look good and not gaudy
* It will do the right thing if output is not a tty
* Can be used as a library or as a program

## TODO

* Configurable themes
* Fix whatever bug is there

## Usage as a program

TBW

## Usage as a library

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     markterm:
       github: your-github-user/markterm
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
