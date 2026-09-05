# Knuth-Liang hyphenation over TeX pattern files.
#
# Patterns interleave letters (with `.` for the word boundary) and
# digits; applying every matching pattern accumulates a score for each
# position between characters, and odd scores mark legal break points.
# The pattern data comes from the TeX hyph-utf8 collection: see
# data/README.md for provenance and licenses.
module Hyphen
  VERSION = "0.1.0"

  # The set of patterns and exceptions for one language.
  class Dictionary
    # Language tag as given to the constructor ("en", "es", ...).
    getter language : String

    # Minimum characters before the first break and after the last one
    # (TeX's \lefthyphenmin and \righthyphenmin).
    getter left_min : Int32
    getter right_min : Int32

    @patterns : Hash(String, Array(Int32))
    @exceptions : Hash(String, Array(Int32))
    @max_key_length : Int32

    # Builds a dictionary from TeX pattern text: `patterns` holds one
    # pattern per line, `exceptions` one word per line with its allowed
    # breaks written as hyphens ("as-so-ciate"; a word without hyphens
    # forbids every break).
    def initialize(patterns : String, exceptions : String = "", language : String = "custom",
                   @left_min : Int32 = 2, @right_min : Int32 = 3)
      @language = language
      @patterns = {} of String => Array(Int32)
      @exceptions = {} of String => Array(Int32)
      patterns.each_line do |line|
        pattern = line.strip
        next if pattern.empty? || pattern.starts_with?('%')
        key, weights = parse_pattern(pattern)
        @patterns[key] = weights
      end
      exceptions.each_line do |line|
        word = line.strip
        next if word.empty? || word.starts_with?('%')
        spelling, positions = parse_exception(word)
        @exceptions[spelling] = positions
      end
      @max_key_length = @patterns.keys.max_of(&.size)
    end

    # Loads one of the pattern sets embedded in the shard: "en" (en-US)
    # or "es" (Spanish). Language tags are matched case-insensitively
    # and accept underscores in place of hyphens. Dictionaries are
    # parsed once and shared.
    def self.load(language : String) : Dictionary
      case language.downcase.tr("_", "-")
      when "en", "en-us"
        embedded["en"]
      when "es", "es-es"
        embedded["es"]
      else
        raise ArgumentError.new("no embedded hyphenation patterns for '#{language}' (available: en, es)")
      end
    end

    # Positions where `word` may break: a break happens before
    # word[position]. Results respect the language's minimum fragment
    # lengths, so words too short to break yield an empty array.
    # Exceptions are honored verbatim: TeX does not apply the minimum
    # fragment lengths to \hyphenation exceptions.
    def points(word : String) : Array(Int32)
      letters = word.downcase.chars
      if exception = @exceptions[letters.join]?
        return exception
      end
      return [] of Int32 if letters.size < left_min + right_min
      liang_points(letters)
    end

    # `word` with a hyphen written at every break point, e.g.
    # "hy-phen-ation": a debugging aid that shows where breaks land.
    def visualize(word : String) : String
      break_points = points(word)
      visualized = IO::Memory.new
      word.chars.each_with_index do |letter, index|
        visualized << '-' if break_points.includes?(index)
        visualized << letter
      end
      visualized.to_s
    end

    # The core scoring pass: pad the word with boundary dots, apply every
    # pattern matching a substring, and keep the positions whose final
    # score is odd.
    private def liang_points(letters : Array(Char)) : Array(Int32)
      padded = ['.'] + letters + ['.']
      weights = Array(Int32).new(padded.size + 1, 0)
      padded.size.times do |start|
        length = 1
        while length <= @max_key_length && start + length <= padded.size
          if matched = @patterns[padded[start, length].join]?
            matched.each_with_index do |weight, offset|
              index = start + offset
              weights[index] = weight if weight > weights[index]
            end
          end
          length += 1
        end
      end
      (left_min..letters.size - right_min).select do |position|
        weights[position + 1].odd?
      end
    end

    # A pattern like ".ach4" becomes the key ".ach" (the letters it must
    # match) plus one weight per boundary between key characters: the
    # digit read after k letters scores the boundary before key
    # character k, and missing digits leave a weight of zero.
    private def parse_pattern(pattern : String) : {String, Array(Int32)}
      key = [] of Char
      weights = [0] of Int32
      pattern.each_char do |character|
        if character.ascii_number?
          weights[key.size] = character.to_i
        else
          key << character
          weights << 0
        end
      end
      {key.join, weights}
    end

    # "as-so-ciate" becomes the plain spelling "associate" and the break
    # positions before each written hyphen.
    private def parse_exception(entry : String) : {String, Array(Int32)}
      parts = entry.downcase.split('-')
      positions = [] of Int32
      parts[0...-1].each do |part|
        positions << (positions.last? || 0) + part.size
      end
      {parts.join, positions}
    end

    private def self.embedded
      @@embedded ||= {
        "en" => new({{ read_file("#{__DIR__}/../data/hyph-en-us.pat.txt") }},
          {{ read_file("#{__DIR__}/../data/hyph-en-us.hyp.txt") }},
          language: "en", left_min: 2, right_min: 3),
        "es" => new({{ read_file("#{__DIR__}/../data/hyph-es.pat.txt") }},
          language: "es", left_min: 2, right_min: 2),
      }
    end
  end
end
