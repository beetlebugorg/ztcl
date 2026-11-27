# References for `ztcl::typeset` and `ztcl::pdf`

The code of `src/typeset/` is our own. It follows the papers and the specifications below. No code comes from TeX, from a PDF library, or from a font library.

## Line breaking

Donald E. Knuth and Michael F. Plass, "Breaking Paragraphs into Lines", *Software: Practice and Experience* 11 (1981), pages 1119 to 1184.

**How ztcl uses it:** `src/typeset/knuth.zig` has the total-fit algorithm of the paper: the box, glue, and penalty model, the active list, the adjustment ratio, the badness 100 |r|^3, the demerits (l + b)^2 plus the square of the penalty, the extra demerits for two flagged breaks in a row, and the four fitness classes. The extra stretch of the last pass has the same idea as `\emergencystretch` of TeX; ztcl took the idea from the documentation of TeX, and no code. `src/typeset/para.zig` has the first-fit method for a comparison.

## Hyphenation

Franklin Mark Liang, "Word Hy-phen-a-tion by Com-put-er", PhD thesis, Stanford University, 1983 (report STAN-CS-83-977).

**How ztcl uses it:** `src/typeset/hyph.zig` has the pattern method of the thesis: the odd and even digits between letters, the maximum over all matching patterns, and the exception list. The patterns go in a trie of our own design.

## Hyphenation patterns

`src/typeset/data/hyph-en-us.pat.txt` and `hyph-en-us.hyp.txt`: the patterns and the exceptions of American English, from the file `hyph-en-us.tex` of the hyph-utf8 package on CTAN (`language/hyph-utf8/tex/patterns/txt/`, downloaded on 2026-11-27). They are the patterns of Liang for plain TeX (`hyphen.tex`), with the additions of Gerard D.C. Kuiken (`ushyphmax.tex`, 1990).

**License:** the header of the file says: "Copyright (C) 1990, 2004, 2005 Gerard D.C. Kuiken. Copying and distribution of this file, with or without modification, are permitted in any medium without royalty provided the copyright notice and this notice are preserved." This license is permissive and has no copyleft term. `src/typeset/data/hyph-en-us.LICENSE` keeps the notice next to the data, with no change to it.

The pattern files of other languages in hyph-utf8 have many licenses, and some are copyleft (LPPL with conditions, GPL, and others). Check the license of each one before it goes into ztcl. ztcl has only the American English patterns today.

## PDF

ISO 32000-2:2020, *Document management: Portable document format, Part 2: PDF 2.0*. ztcl used the sections on the file structure (the header, the objects, the cross-reference table, and the trailer), the filters (FlateDecode with the PNG predictors, and DCTDecode), text (the text operators, composite fonts with Identity-H, embedded font programs, and ToUnicode maps), images and soft masks, link annotations and their actions, destinations, the document outline, and page labels. The output is PDF 1.7, the version of ISO 32000-1, with no feature of 2.0 that a 1.7 reader does not have. PDF/A is not in this version.

## Fonts

The OpenType specification (Microsoft and Adobe), for the tables `cmap`, `head`, `hhea`, `hmtx`, `maxp`, `loca`, `glyf`, `name`, `OS/2`, `post`, `GPOS` (pair kerning, lookup type 2), and `GSUB` (ligatures, lookup type 4, and extension lookups). `src/typeset/ttf.zig` is the parser of ztk (`src/text/ttf.zig`), so the two projects have one parser.

The subset of a font (`src/typeset/subset.zig`) keeps the glyph numbers and empties the glyphs that the document does not use, as ISO 32000-2 permits for a font of a CIDFontType2 with the identity map.

## The fonts of the book

`book/fonts/` has three families of Adobe, from the static TrueType files that Google Fonts serves (downloaded on 2026-11-27):

- Source Serif 4, optical size 10 (Regular, Italic, Semibold, Semibold Italic): the text.
- Source Sans 3 (Regular, Semibold): the headings, the running heads, and the labels.
- Source Code Pro (Regular, Semibold): the code.

**License:** SIL Open Font License 1.1, with the Reserved Font Name "Source". The text is in `book/fonts/OFL.txt`. A PDF of the book embeds subsets of the fonts, as the license permits. The files in `book/fonts/` have no change.
