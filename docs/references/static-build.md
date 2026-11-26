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

## Binaries

### The code signature of Mach-O

Apple, `osfmk/kern/cs_blobs.h` in the xnu source (the public headers of the kernel), with the constants `CSMAGIC_EMBEDDED_SIGNATURE`, `CSMAGIC_CODEDIRECTORY`, `CS_ADHOC`, `CS_HASHTYPE_SHA256`, and `CS_EXECSEG_MAIN_BINARY`, and the fields of the code directory up to version 0x20400. https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h

**License:** APSL 2.0. ztcl has no code of the file. It uses the layout of the structures and the values of the constants.

**How ztcl uses it:** `src/macho.zig` writes a SuperBlob with one code directory: the identifier, the SHA-256 hash of each 4 KiB page, and the range of `__TEXT`.

### Mach-O load commands

Apple, `EXTERNAL_HEADERS/mach-o/loader.h` in the xnu source. https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h

**License:** APSL 2.0. ztcl has no code of the file.

**How ztcl uses it:** `src/macho.zig` reads `mach_header_64`, `segment_command_64`, `section_64`, and `linkedit_data_command` (`LC_CODE_SIGNATURE`).
