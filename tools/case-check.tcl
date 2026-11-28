# Prints the case maps and the case classes of each code point from 0 to
# 0x1FFFF with no surrogate, one line each: the code point, its
# lowercase, its uppercase, its titlecase, and `string is upper` and
# `string is lower`, in decimal. Run it in tclsh and in ztcl and compare
# the output, or its SHA-256 with the test of src/ucd.zig. tclsh on
# Windows ends each line with CR LF: drop the CR before the hash.
#
#   tclsh tools/case-check.tcl > tcl.txt
#   zig-out/bin/ztcl --tcl 9.1 tools/case-check.tcl > ztcl.txt
#
# SPDX-License-Identifier: BSD-2-Clause

for {set c 0} {$c < 0x20000} {incr c} {
    if {$c >= 0xD800 && $c <= 0xDFFF} continue
    set ch [format %c $c]
    scan [string tolower $ch] %c l
    scan [string toupper $ch] %c u
    scan [string totitle $ch] %c t
    puts "$c $l $u $t [string is upper $ch] [string is lower $ch]"
}
