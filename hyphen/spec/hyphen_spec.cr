require "spec"
require "../src/hyphen"

# Golden values produced with pyphen (LibreOffice's hyphenator) over the
# same TeX pattern data, including "ar-gu-ment", the known quirk of the
# en-US patterns. pyphen falls back to 2/2 minimum fragment lengths when
# a dictionary has no header; here the pattern sets' own values apply
# (en-US 2/3), so "computer" breaks as com-pu-ter and not com-put-er.
GOLDEN_POINTS = {
  "en" => {
    "hyphenation"          => [2, 6],
    "supercalifragilistic" => [2, 5, 8, 13, 17],
    "project"              => [] of Int32,
    "table"                => [2],
    "present"              => [] of Int32,
    "argument"             => [2, 4],
    "interactive"          => [2, 5, 7],
    "computer"             => [3],
  },
  "es" => {
    "computadora"   => [5, 9],
    "bicicleta"     => [2, 4, 7],
    "internacional" => [2, 5, 7, 10],
    "hipopotamo"    => [2, 4, 6, 8],
    "electricidad"  => [4, 7, 9],
    "casa"          => [2],
    "ñandú"         => [3],
  },
}

describe Hyphen::Dictionary do
  describe ".load" do
    it "raises ArgumentError for languages without embedded patterns" do
      expect_raises(ArgumentError, "es-419") do
        Hyphen::Dictionary.load("es-419")
      end
    end

    it "matches language tags case-insensitively, underscores included" do
      Hyphen::Dictionary.load("EN-US").language.should eq "en"
      Hyphen::Dictionary.load("en_us").language.should eq "en"
      Hyphen::Dictionary.load("es").language.should eq "es"
    end

    it "shares one dictionary per language" do
      Hyphen::Dictionary.load("en").should be Hyphen::Dictionary.load("en-us")
    end
  end

  describe "#points" do
    GOLDEN_POINTS.each do |language, words|
      dictionary = Hyphen::Dictionary.load(language)
      words.each do |word, expected|
        it "finds #{expected.inspect} in #{word.inspect} (#{language})" do
          dictionary.points(word).should eq expected
        end
      end
    end

    it "scores capitalized words after downcasing" do
      Hyphen::Dictionary.load("en").points("Hyphenation").should eq [2, 6]
    end

    it "refuses words too short to break legally" do
      Hyphen::Dictionary.load("en").points("word").should be_empty
      Hyphen::Dictionary.load("es").points("sol").should be_empty
    end

    it "keeps accents intact when matching Spanish words" do
      Hyphen::Dictionary.load("es").points("eléctrico").size.should be > 0
    end
  end

  describe "#visualize" do
    it "writes a hyphen at every break point" do
      Hyphen::Dictionary.load("en").visualize("hyphenation").should eq "hy-phen-ation"
      Hyphen::Dictionary.load("es").visualize("ñandú").should eq "ñan-dú"
    end
  end

  describe "#left_min and #right_min" do
    it "uses the language's TeX minimum fragment lengths" do
      Hyphen::Dictionary.load("en").left_min.should eq 2
      Hyphen::Dictionary.load("en").right_min.should eq 3
      Hyphen::Dictionary.load("es").right_min.should eq 2
    end
  end

  describe "custom dictionaries" do
    it "honors explicit weights and minimum fragment lengths" do
      dictionary = Hyphen::Dictionary.new("a1b2c", language: "test", left_min: 1, right_min: 1)
      dictionary.points("abc").should eq [1]
      strict = Hyphen::Dictionary.new("a1b2c", language: "test", left_min: 2, right_min: 2)
      strict.points("abc").should be_empty
    end

    it "restricts words listed as exceptions to their written breaks" do
      dictionary = Hyphen::Dictionary.new("t1ypo\nxy1z", exceptions: "ty-po", language: "test",
        left_min: 1, right_min: 1)
      dictionary.points("typo").should eq [2]
      dictionary.points("typox").should eq [1]
      dictionary.points("xyz").should eq [2]
    end

    it "applies exceptions verbatim, without minimum fragment lengths" do
      dictionary = Hyphen::Dictionary.new("pre2sent", exceptions: "pre-sent", language: "test",
        left_min: 4, right_min: 4)
      dictionary.points("present").should eq [3]
    end

    it "forbids every break for exceptions written without a hyphen" do
      dictionary = Hyphen::Dictionary.new("pre2sent", exceptions: "present", language: "test",
        left_min: 1, right_min: 1)
      dictionary.points("present").should be_empty
    end
  end
end
