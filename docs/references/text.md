# References for ztcl::text

The segmenters and the width of `src/text/` are new code, written from the Unicode standards below. ztcl reads no code of ICU or of another segmentation library.

## The Unicode standards

- UAX #29, Unicode Text Segmentation, revision 49, for Unicode 18.0.0. https://www.unicode.org/reports/tr29/tr29-49.html. **What ztcl takes:** the rules GB1 to GB999 of extended grapheme clusters, WB1 to WB999 of words, and SB1 to SB998 of sentences, with the ignore rules of section 6.2. `src/text/seg.zig` names each rule at its line.
- UAX #11, East Asian Width. https://www.unicode.org/reports/tr11/. **What ztcl takes:** the classes W and F as two columns, and A as one column or two by an option.
- UTS #51, Unicode Emoji. https://www.unicode.org/reports/tr51/. **What ztcl takes:** Emoji_Presentation as two columns, and the effect of U+FE0F after an emoji.

**License:** the Unicode License V3, [licenses/unicode-license.txt](../../licenses/unicode-license.txt).

## The Unicode Character Database 18.0.0

https://www.unicode.org/Public/18.0.0/ucd/. **License:** the Unicode License V3, [licenses/unicode-license.txt](../../licenses/unicode-license.txt).

- `tools/text-gen.py` reads `auxiliary/GraphemeBreakProperty.txt`, `auxiliary/WordBreakProperty.txt`, `auxiliary/SentenceBreakProperty.txt`, `DerivedCoreProperties.txt` (Indic_Conjunct_Break and Default_Ignorable_Code_Point), `emoji/emoji-data.txt`, `EastAsianWidth.txt`, and `extracted/DerivedGeneralCategory.txt`, and writes `src/text/tables.zig`.
- `src/testdata/unicode/` has copies of `auxiliary/GraphemeBreakTest.txt`, `auxiliary/WordBreakTest.txt`, and `auxiliary/SentenceBreakTest.txt`. `zig build test` runs each line of the three files.

## ICU

ICU 78.3, https://icu.unicode.org. **License:** the Unicode License V3. **How ztcl uses it:** a peer in the benchmark only. `bench/text/icu.c` calls the public `ubrk_` API of the installed library to count the clusters, the words, and the sentences of the same texts. ztcl reads no ICU source.
