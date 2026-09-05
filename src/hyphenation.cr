require "hyphen"

module Markd
  module Pdf
    # Words shorter than this are never worth hyphenating.
    MINIMUM_HYPHENATED_LENGTH = 5

    # Elements whose contents are never hyphenated: code, formulas and
    # anything a renderer would not wrap word-by-word either.
    NO_HYPHENATION_ELEMENTS = {"pre", "code", "script", "style"}

    # Inserts soft hyphens (&#173;) at the hyphenation points of the
    # words in the HTML text nodes, so the layout engine can break long
    # words at the end of a justified line (the soft hyphen only shows
    # when the break is taken). Tags, attributes and entities pass
    # through untouched, as do the contents of the elements in
    # NO_HYPHENATION_ELEMENTS and math spans. Only pure-letter words are
    # considered, and all-lowercase ones at that: capitalized words are
    # never split, following TeX's \uchyph=0 convention.
    def self.insert_soft_hyphens(html : String, language : String = "en") : String
      dictionary = Hyphen::Dictionary.load(language)
      data = html.to_slice
      output = IO::Memory.new
      word = IO::Memory.new
      index = 0
      while index < data.size
        byte = data[index]
        if byte == '<'.ord
          flush_word(word, output, dictionary)
          index = copy_tag(data, index, output)
        elsif byte == '&'.ord
          flush_word(word, output, dictionary)
          index = copy_entity(data, index, output)
        elsif letter_byte?(byte)
          word.write_byte(byte)
          index += 1
        else
          flush_word(word, output, dictionary)
          output.write_byte(byte)
          index += 1
        end
      end
      flush_word(word, output, dictionary)
      output.to_s
    end

    # Writes the accumulated word with a soft hyphen inserted at every
    # break point.
    private def self.flush_word(word : IO::Memory, output : IO::Memory, dictionary : Hyphen::Dictionary)
      text = word.to_s
      word.clear
      points = hyphenation_points(text, dictionary)
      if points.empty?
        output << text
        return
      end
      previous = 0
      points.each do |point|
        output << text[previous...point] << "&#173;"
        previous = point
      end
      output << text[previous..]
    end

    # Hyphenation points of a word, or an empty array when the word is
    # not worth splitting: too short, or with any uppercase anywhere
    # (proper names, acronyms, sentence starts).
    private def self.hyphenation_points(text : String, dictionary : Hyphen::Dictionary) : Array(Int32)
      return [] of Int32 if text.size < MINIMUM_HYPHENATED_LENGTH
      return [] of Int32 unless text.downcase == text
      dictionary.points(text)
    end

    # ASCII letters and anything multi-byte (letters of languages other
    # than English); digits and punctuation end a word.
    private def self.letter_byte?(byte : UInt8) : Bool
      return true if byte >= 0x80
      (byte >= 'A'.ord && byte <= 'Z'.ord) || (byte >= 'a'.ord && byte <= 'z'.ord)
    end

    # Copies a tag verbatim. Code-bearing elements and math spans also
    # copy their contents verbatim, up to their closing tag. Returns the
    # index of the first byte after the copied text.
    private def self.copy_tag(data : Bytes, start : Int32, output : IO::Memory) : Int32
      closing = data[start + 1]? == '/'.ord
      name_start = closing ? start + 2 : start + 1
      name_end = name_start
      while name_end < data.size && ascii_letter_byte?(data[name_end])
        name_end += 1
      end
      tag_name = String.new(data[name_start...name_end])
      cursor = find_tag_end(data, name_end)
      if !closing && NO_HYPHENATION_ELEMENTS.includes?(tag_name)
        return copy_until_close_tag(data, start, cursor, "</#{tag_name}>", output)
      end
      if !closing && math_span_start?(data, start, cursor)
        return copy_math_span(data, start, cursor, output)
      end
      output.write(data[start...cursor])
      cursor
    end

    private def self.ascii_letter_byte?(byte : UInt8) : Bool
      (byte >= 'A'.ord && byte <= 'Z'.ord) || (byte >= 'a'.ord && byte <= 'z'.ord)
    end

    # Index just past the '>' closing the tag, honoring quoted attribute
    # values that may contain '>'.
    private def self.find_tag_end(data : Bytes, from : Int32) : Int32
      cursor = from
      while cursor < data.size
        case data[cursor]
        when '"'.ord
          closing_quote = find_bytes(data, "\"".to_slice, cursor + 1)
          cursor = closing_quote || data.size
        when '>'.ord
          return cursor + 1
        end
        cursor += 1
      end
      data.size
    end

    # True when the tag at [start, cursor) is a span holding math.
    private def self.math_span_start?(data : Bytes, start : Int32, cursor : Int32) : Bool
      String.new(data[start...cursor]).match(/<span\b[^>]*class="math[^"]*"/) != nil
    end

    # Copies up to the element's closing tag, which is where the
    # contents end. Without a closing tag (malformed HTML), everything
    # left is copied.
    private def self.copy_until_close_tag(data : Bytes, start : Int32, tag_end : Int32,
                                          close_tag : String, output : IO::Memory) : Int32
      closing_index = find_bytes(data, close_tag.to_slice, tag_end) || data.size
      output.write(data[start...closing_index])
      closing_index
    end

    # Copies a math span: up to the matching </span>, accounting for
    # nested spans.
    private def self.copy_math_span(data : Bytes, start : Int32, tag_end : Int32, output : IO::Memory) : Int32
      depth = 1
      cursor = tag_end
      while depth > 0
        open_index = find_bytes(data, "<span".to_slice, cursor)
        close_index = find_bytes(data, "</span>".to_slice, cursor)
        if close_index.nil?
          return data.size
        end
        if open_index && open_index < close_index
          depth += 1
          cursor = open_index + 5
        else
          depth -= 1
          cursor = close_index + 7
        end
      end
      output.write(data[start...cursor])
      cursor
    end

    # Copies an entity (&amp;, &#173;, ...) verbatim: a word never
    # hyphenates across or inside one. A stray '&' is copied as-is.
    private def self.copy_entity(data : Bytes, start : Int32, output : IO::Memory) : Int32
      semicolon = find_bytes(data, ";".to_slice, start + 1)
      if semicolon.nil? || semicolon > start + 10
        output.write_byte(data[start])
        return start + 1
      end
      output.write(data[start..semicolon])
      semicolon + 1
    end

    private def self.find_bytes(data : Bytes, needle : Bytes, from : Int32) : Int32?
      last = data.size - needle.size
      cursor = from
      while cursor <= last
        return cursor if data[cursor, needle.size] == needle
        cursor += 1
      end
      nil
    end
  end
end
