# Writes src/ucd_case.zig, the simple case maps and the case classes of
# src/ucd.zig, from UnicodeData.txt of the Unicode Character Database:
#
#   zig-out/bin/ztcl --allow file,channels tools/ucd-case.tcl \
#       UnicodeData.txt 17.0.0 src/ucd_case.zig
#   zig fmt src/ucd_case.zig
#
# The maps are the fields 12 to 14 of each line: the uppercase, the
# lowercase, and the titlecase. An empty titlecase is the uppercase. A
# map whose result has a longer UTF-8 form than the character is left
# out, as in Tcl: the lowercase of U+023A (two bytes) is U+2C65 (three
# bytes), so U+023A keeps its case. A map to a shorter form stays: the
# lowercase of U+0130 is `i`.
#
# The classes are the general categories Lu, Ll, and Lt (field 2).
#
# The tables have two stages. `blocks` gives a block of 128 entries for
# each 128 code points, and `items` gives an index into `cases` for each
# code point of a block. Blocks with the same entries are one block.
#
# SPDX-License-Identifier: BSD-2-Clause

lassign $argv in version out
if {$out eq ""} {
    puts stderr "usage: ucd-case.tcl UnicodeData.txt VERSION OUT.zig"
    exit 2
}

proc u8len {c} {
    expr {$c < 0x80 ? 1 : $c < 0x800 ? 2 : $c < 0x10000 ? 3 : 4}
}

# The change of a map, or 0 for no map or a map to a longer form.
proc delta {c field} {
    if {$field eq ""} { return 0 }
    scan $field %x m
    if {[u8len $m] > [u8len $c]} { return 0 }
    return [expr {$m - $c}]
}

set kinds {Lu 1 Ll 2 Lt 3}
set f [open $in r]
set top 0
while {[gets $f line] >= 0} {
    set fl [split $line ";"]
    scan [lindex $fl 0] %x c
    set kind [expr {[dict exists $kinds [lindex $fl 2]] ? [dict get $kinds [lindex $fl 2]] : 0}]
    set ti [lindex $fl 14]
    if {$ti eq ""} { set ti [lindex $fl 12] }
    set e [list [delta $c [lindex $fl 13]] [delta $c [lindex $fl 12]] [delta $c $ti] $kind]
    if {$e eq {0 0 0 0}} continue
    set entry($c) $e
    if {$c > $top} { set top $c }
}
close $f

# The cases: each distinct entry, with the empty one first.
set cases [list {0 0 0 0}]
set case_index [dict create {0 0 0 0} 0]
set blocks {}
set items {}
set block_index [dict create]
set nblocks [expr {($top >> 7) + 1}]
for {set b 0} {$b < $nblocks} {incr b} {
    set row {}
    for {set c [expr {$b << 7}]} {$c < (($b + 1) << 7)} {incr c} {
        set e [expr {[info exists entry($c)] ? $entry($c) : {0 0 0 0}}]
        if {![dict exists $case_index $e]} {
            dict set case_index $e [llength $cases]
            lappend cases $e
        }
        lappend row [dict get $case_index $e]
    }
    if {![dict exists $block_index $row]} {
        dict set block_index $row [expr {[llength $items] / 128}]
        lappend items {*}$row
    }
    lappend blocks [dict get $block_index $row]
}
if {[llength $cases] > 256 || [llength $items] / 128 > 256} {
    puts stderr "ucd-case.tcl: more than 256 cases or blocks: the tables need u16 indexes"
    exit 1
}

proc rows {list per} {
    set out {}
    for {set i 0} {$i < [llength $list]} {incr i $per} {
        append out "    [join [lrange $list $i [expr {$i + $per - 1}]] {, }],\n"
    }
    return $out
}

set kind_names {none upper lower title}
set o [open $out w]
fconfigure $o -translation lf
puts $o "//! The simple case maps and the case classes of the Unicode Character"
puts $o "//! Database $version, from UnicodeData.txt. Made by tools/ucd-case.tcl."
puts $o "//! Do not edit."
puts $o "//!"
puts $o "//! The data: Copyright © 1991-2026 Unicode, Inc., under the Unicode"
puts $o "//! License V3 (licenses/unicode-license.txt)."
puts $o ""
puts $o "pub const unicode_version = \"$version\";"
puts $o ""
puts $o "pub const Kind = enum(u2) { none, upper, lower, title };"
puts $o ""
puts $o "/// The changes of the lowercase, the uppercase, and the titlecase, and"
puts $o "/// the class."
puts $o "pub const Case = struct { lower: i32, upper: i32, title: i32, kind: Kind };"
puts $o ""
puts $o "/// The code points from this one on have no case."
puts $o "pub const end: u21 = [format 0x%X [expr {$nblocks << 7}]];"
puts $o ""
puts $o "pub const cases = \[_\]Case\{"
foreach e $cases {
    lassign $e lo up ti kind
    puts $o "    .{ .lower = $lo, .upper = $up, .title = $ti, .kind = .[lindex $kind_names $kind] },"
}
puts $o "\};"
puts $o ""
puts $o "/// The block of each 128 code points."
puts $o "pub const blocks = \[_\]u8\{"
puts -nonewline $o [rows $blocks 16]
puts $o "\};"
puts $o ""
puts $o "/// The index into `cases` of each code point of each block."
puts $o "pub const items = \[_\]u8\{"
puts -nonewline $o [rows $items 16]
puts $o "\};"
close $o
puts "[llength $cases] cases, [expr {[llength $items] / 128}] blocks of [llength $blocks], up to [format %X [expr {$nblocks << 7}]]"
