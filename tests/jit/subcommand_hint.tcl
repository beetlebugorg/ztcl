# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the subcommand hint of a site of `info` and `string`.
# A rename, an expanded word, and a prefix find the subcommand again.
proc f {x} {
    set r {}
    lappend r [info exists x] [info exi x] [string length $x] [string len $x]
    lappend r [catch {info e x} m] $m
    lappend r [catch {string bogus $x} m] $m
    return $r
}
for {set i 0} {$i < 3} {incr i} { puts [f abc] }
proc sl {args} { string {*}$args }
proc g {x} { list [sl length $x] [sl toupper $x] [info exists x] [info exists nosuch] }
for {set i 0} {$i < 3} {incr i} { puts [g hello] }
rename string string_orig
proc string {args} { return "custom $args" }
for {set i 0} {$i < 2} {incr i} { puts [f abc] }
rename string {}
rename string_orig string
for {set i 0} {$i < 2} {incr i} { puts [f abc] }
proc h {s} { set out {}; foreach w {length toupper} { lappend out [string $w $s] }; return $out }
puts [h abc]
