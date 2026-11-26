# References for static binaries and the virtual file system

[The plan](../dev/static-build.md) and its code use these sources. ztcl has no code of any of them.

## Zip archives

### The zip file format

PKWARE, "APPNOTE.TXT: .ZIP File Format Specification", version 6.3.10, 2022. https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT

**License:** Specification.

**How ztcl uses it:** `src/zipread.zig` reads the end of central directory record, the zip64 locator and record, the central headers, the local headers, the zip64 extra field (0x0001), and the extended time extra field (0x5455) as the specification gives them.

### The zipfs command of Tcl 9

The Tcl 9.0 manual page of `zipfs`. https://www.tcl-lang.org/man/tcl9.0/TclCmd/zipfs.html

**License:** Documentation. Tcl is under the Tcl license.

**How ztcl uses it:** The names and the arguments of `zipfs mount`, `unmount`, `list`, `info`, `exists`, and `root`, and the volume `//zipfs:/`, follow the manual page. ztcl has no code of Tcl.

## Deflate

### The deflate format

L. Peter Deutsch, "DEFLATE Compressed Data Format Specification version 1.3", RFC 1951, 1996. https://www.rfc-editor.org/rfc/rfc1951

**License:** RFC.

**How ztcl uses it:** `src/inflate.zig` decodes the three block types, the length and distance tables, and the code length alphabet of the RFC.

### A canonical Huffman decoder

Mark Adler, puff.c, a small inflate in the zlib source tree (contrib/puff). https://github.com/madler/zlib/tree/develop/contrib/puff

**License:** zlib license.

**How ztcl uses it:** `src/inflate.zig` uses the method of puff: a table of the count of codes of each length and the symbols in code order, a decode that compares the code with the first code of each length, and a check for over-subscribed and incomplete codes. The Zig code is new.

## Dates

### Days from a civil date

Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms", the `days_from_civil` algorithm. https://howardhinnant.github.io/date_algorithms.html

**License:** Article. The author puts the algorithms in the public domain.

**How ztcl uses it:** `dosTime` in `src/zipread.zig` turns the DOS date of a zip entry into days since 1970 with this algorithm.
